# App Buffers: non-file-backed interactive views

## Goal

Allow non-file-backed ("scratch") buffers that the user drives via arrow keys,
Enter, and custom commands **as if it were a TUI application** — file pickers,
git-status views, outline/dashboards, command result lists, etc.

## Core principle

**Buffers are the Cartesian substrate of everything** (the Emacs model). The
buffer's text is always the entire source of truth for what is on screen: a
list's items *are* its lines, its "selected row" *is* the cursor's line, its
highlight is the active-line tint. There is **no custom render function** and
no parallel UI data model. A "TUI app" is just:

> A scratch `Buffer` + `View` whose active `MajorMode` customizes *behavior*
> (keybindings, printable-char handling, multi-cursor policy) and *display
> toggles* (gutter/wrap/cursor style) — never appearance-as-data.

Everything renderable continues to flow through the standard pipeline; the
flags only flip standard knobs the pipeline already has.

## Decisions (locked)

1. **Carrier = `MajorMode`.** Extend `MajorMode` with the new hooks/flags. A
   special buffer is a view whose (only) mode sets them. Reuses the existing
   trie-merge + `mode_enter`/`mode_exit` lifecycle. No new `AppView` type.
2. **Selection = the text cursor.** `cursor.line` = selected row, `col = 0`.
   Multi-cursor infra lies dormant (disabled by flag). No new selection model.
3. **Input = per-mode `printable`.** Add a `printable` hook to `MajorMode`;
   `process_key` consults the focused view's top mode before the global
   `__printable`. The rest of the interception chain (read-char / completion
   menu / digit / universal arg) stays hardcoded.
4. **Lifecycle = persistent.** Special buffers are first-class entries in
   `editor.views` (added via `add_view`, focused via `set_active_view`, closed
   via `kill_buffer`/`close_view`, switched via `next_view`). A transient
   overlay layer (the generalized minibuffer) is deferred to v2.
5. **Buffer seeding = `on_enter`.** A mode populates its own buffer lines via
   `mode_enter` (the existing lifecycle event). `on_enter`/`on_exit` are
   convenience properties that auto-wire `mode_enter:<name>` / `mode_exit:<name>`
   listeners. No special "open app" helper — the construction is the normal
   view-creation flow.

## `MajorMode` additions

```lua
--- behavior hooks ---
---@field printable? fun(view, editor, ch): boolean?  nil → global __printable
---@field multi_currency? boolean                      default true; false → multi-cursor cmds no-op
---@field on_enter? fun(view, editor, instance)        auto-wires mode_enter:<name>
---@field on_exit?  fun(view, editor, instance)        auto-wires mode_exit:<name>

--- display toggles (resolved onto the view like tab_width/expand_tab/margin) ---
---@field no_gutter? boolean         drop the whole gutter (numbers + signs + separators)
---@field no_line_numbers? boolean  keep gutter frame, blank the numbers (no_gutter implies this)
---@field no_wrap? boolean          one sub-row per line (do not set wrap_width)
---@field whole_line_cursor? boolean cursor paints the entire row in cursor_bg instead of one cell
```

`on_enter`/`on_exit` auto-registration is wired lazily & idempotently per
editor from `View:_emit_mode_event` (the single chokepoint for enter/exit
across `activate_major_mode`, `activate_mode_for_filepath`, and
`deactivate_major_mode`), so the listener exists *before* the event is emitted
and catches the first activation.

## Dispatch / input changes

### `main.lua:process_key` — per-mode printable

In the unmodified-printable branch, consult the focused view's top mode first:

```lua
local mode = view and view:top_mode()
local pfn = (mode and mode.printable) or editor._printable_fn
```

Protocol unchanged from today's `__printable`: return truthy → feed the trie
(command-letter/vim-style apps); return false/nil → handled (filter/insert
apps, e.g. appending to a filter string and rewriting the buffer).

### Multi-cursor guard

`view:multi_cursor_enabled()` reads the top mode's `multi_currency` flag.
`select_next_match` / `add_cursor` / `select_all_matches` / `drop_cursor` and
mouse Alt-click no-op when false. (These commands are unreachable via keys in
an app mode anyway since the mode doesn't bind them — this guards `M-x`.)

## Render changes (flags only; standard pipeline otherwise unchanged)

- **`no_gutter`** → `View:text_geometry` returns `gutter_width = 0` (text_x =
  block_x; margin centering still works); render skips the line-number + sign
  paint block.
- **`no_line_numbers`** → keeps the gutter cells but blanks the number string.
- **`no_wrap`** → `Editor:render` does *not* assign
  `view.wrap_width = text_width` (leaves it nil); `View:wrap_rows` already
  returns one sub-row when width is nil — free.
- **`whole_line_cursor`** → the cursor overlay paints the full sub-row width in
  `cursor_bg` (with `no_wrap`, the whole line = the "selected row" highlight).

Syntax spans, selection overlay, indent guides, and pending-drop markers all
keep running — they're buffer-text-derived, which is the point. All flags
default off → zero change to existing file-buffer rendering.

## Construction (no helper; the normal flow)

```lua
local view = View.new(Buffer.new())   -- scratch: filepath nil, no mmap
view.file_loaded = true
view._items = items                   -- pass data on the view before activating
editor:add_view(view)                 -- sets view.editor, focuses, emits view_open
view:activate_major_mode(Picker)      -- mode_enter:<name> fires → on_enter(view, editor) seeds buffer
```

`add_view` must run before `activate_major_mode`: `_emit_mode_event` no-ops when
`view.editor` is nil, so `on_enter` requires the editor ref. This is sub-frame
(no render between them) — no flicker.

## Worked example — a file picker

```lua
local Picker = MajorMode.new({
    name = "picker",
    no_gutter = true, no_wrap = true, whole_line_cursor = true, multi_currency = false,
    on_enter = function(view, editor)
        view:refilter()               -- seed buffer lines from view._items
    end,
    keybindings = {
        ["up"] = "previous_line",
        ["down"] = "next_line",
        ["enter"] = function(view, editor) view:fire_on_select() end,
        ["backspace"] = function(view, editor) view:trim_filter() end,
        ["q"] = "kill_buffer",
    },
    printable = function(view, editor, ch)
        view._filter = (view._filter or "") .. ch
        view:refilter()
    end,
})
```

The list *is* the buffer's lines. Typing filters by rewriting those lines
(`refilter` = buffer text mutation, nothing render-side). The selected row *is*
`cursor.line`, highlighted by the whole-line caret tint + active-line tint.

## What this retires / defers

- **Structurally retires** the `if editor.minibuffer.active` scattering in
  `enter_key` / `arrow_up_select` / `tab_key` / `cancel` — *once* the
  minibuffer migrates to a MajorMode. That migration requires the **transient
  overlay** path + `focused_view()` generalization, scoped out of v1. v1 leaves
  the minibuffer as-is and builds the new capability alongside it.
- **Deferred to v2:** transient overlay views (`open_app(..., {transient=true})`
  pop over the current view, grab focus, close-to-restore) and the generalized
  `focused_view()` redirect that subsumes the minibuffer.

## Change footprint

1. `major_mode.lua` — 6 new optional fields + `_ensure_listeners` + spec docs.
2. `view.lua` — `_emit_mode_event` ensures listeners; `View:top_mode()`;
   `set_major_modes` copies display flags; `text_geometry` honors `no_gutter`.
3. `editor.lua` (`Editor:render`) — `no_wrap` gate, gutter/line-number skip,
   `whole_line_cursor` overlay variant.
4. `main.lua:process_key` — per-mode `printable` lookup.
5. `commands.lua` — multi-currency guards (4 commands) + mouse Alt-click guard.
