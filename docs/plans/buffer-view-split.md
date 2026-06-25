# Buffer/View Split — Architecture Plan

## Goal

Extract Editor into three clean abstractions:
- **Buffer** — owns the piece table, undo log, and all text operations
- **View** — owns cursor, scroll, mark, selection, per-view edit grouping
- **Editor** — orchestrates views, renders, dispatches keybindings

## New Data Structures

### Buffer (C struct + Lua wrapper)

```c
// C struct (in shared_state.h or new buffer.h)
struct Buffer {
    struct Line  *lines;
    uint32_t      cap;
    uint32_t      count;
    bool          dirty;
    struct OrigBuf orig;
    struct AddBuf  add;
    struct UndoLog undo;
    struct UndoLog redo;
    uint32_t       in_edit;  /* nesting counter for the buffer's open edit group */
};
```

Lua wrapper (`src/cursed/buffer.lua`):
- `Buffer.new()` — allocates C struct, returns Lua object with wrap_gc finalizer
- `Buffer.from_mmap(data, len, cap)` — constructs from IO lane's mmap'd orig data
- All piece table mutation, text extraction, undo/redo, and search methods

### View (pure Lua table)

```lua
---@class View
---@field buffer Buffer shared reference (not owned)
---@field cursor_line integer
---@field cursor_col integer
---@field last_cursor_col integer
---@field scroll_y integer
---@field mark_line integer|nil
---@field mark_col integer|nil
---@field in_edit boolean whether this view has an open edit group
```

Why pure Lua? View doesn't need FFI, doesn't cross lane boundaries,
and its fields are all simple scalars. No C struct needed.

### Editor (pure Lua table)

```lua
---@class Editor
---@field views View[] list of open views
---@field active_view integer index into views
---@field term Term
---@field status_message string|nil
```

Editor renders the active view, dispatches keybindings to the active view.

### SharedState (simplified)

SharedState loses the PieceTable. It becomes purely an IPC mechanism:

```c
struct SharedState {
    void          *io_orig_data;   /* IO lane sets, main lane reads & clears */
    uint32_t       io_orig_len;
    uint32_t       io_orig_cap;
    struct RingBuf outbox_io;
    struct RingBuf inbox_io;
    _Atomic bool   running;
};
```

The IO lane mmaps a file and writes the pointer/len/cap fields.
The main lane reads them, constructs a `Buffer.from_mmap()`, then zeroes the fields.
This enables multiple file loads — each creates a new Buffer.

## Method Migration

### Buffer gets (from SharedState + editor_ops):

**Low-level (piece table internals):**
- grow_add, append_add, grow_lines, shift_lines_right, grow_pieces
- set_piece, get_piece, set_piece_count
- init_line, insert_line

**Mid-level (piece table mutation):**
- insert, delete, split_line, join_lines
- find_piece, line_len

**High-level (text editing — returns cursor positions):**
- insert_char(str) → Point (where cursor should end up)
- delete_char(n) → Point (where cursor should end up)
- insert_newline() → Point
- should_break_edit(str) → boolean (helper for edit gating)
- delete_selection(view) → boolean (combines selection_range + delete_char)

**High-level (text extraction):**
- line_text, line_text_range, text_range, text

**Undo/redo (buffer owns in_edit):**
- begin_edit, end_edit, in_edit, close_edit, undo, redo
- (internal: log_pack, log_apply_last, log_pop, log_reset, log_grow, log_ensure)

**Search:**
- search_forward, search_backward, search_regex, search_regex_backward

**File loading:**
- build_lines_from_orig
- from_mmap (constructor)

**Accessors:**
- line_count, piece_count, add_len
- is_dirty, clear_dirty
- filepath, set_filepath

### View gets (from Editor — pure viewport, no mutation):

**Cursor/motion:**
- move_char, move_line, move_page, move_line_start, move_line_end, move_word
- cursor_left/right/up/down
- close_edit_for_motion() → calls buffer:close_edit()

**Mark/selection:**
- set_mark, unset_mark, has_selection, selection_range, swap_mark_and_cursor

**Helpers:**
- content_len, line_count, chars_between, text_between

### Editor keeps:

**Rendering:**
- render() — reads active view + its buffer, paints to Term

**Orchestration:**
- keybinding dispatch (gives keybinding functions view + editor)

**State:**
- views list, active_view index
- status_message
- filepath (per-buffer)
- file_loaded flag (per-view)

## GC / Memory Management

- Buffer's Lua wrapper holds the C struct pointer via wrap_gc
- Finalizer frees: each line's pieces, lines array, add buffer data,
  undo log mmap, redo log mmap, orig buffer mmap (if present), then the struct itself
- View holds a Buffer reference but does NOT own it — GC handles refcounting naturally
- SharedState's orig pointer is NOT wrapped in wrap_gc — it's handed off to Buffer,
  which takes ownership

## Edit Grouping Rules (per-view)

1. `view.in_edit` tracks whether the view has an open edit group on its buffer
2. Motions close the view's edit group before moving (close_edit_for_motion)
3. `insert_char` checks `should_break_edit` — alphanumeric continues the group,
   non-alnum/newline breaks it
4. `delete_char` checks `will_join` — same-line deletions continue the group,
   line joins break it
5. When a view's edit group is open, it means the buffer has a matching open
   snapshot. Buffer.in_edit == 1.
6. **If view A has an open group and view B starts editing**: view A's group
   must be closed first (view A's in_edit → false, buffer's end_edit called),
   then view B can start its own group. This prevents interleaved edit groups.

## File Layout

```
src/
├── cursed/
│   ├── buffer.lua          — Buffer: piece table, undo, search, text extraction
│   ├── view.lua            — View: cursor, selection, edit grouping, motions
│   ├── editor.lua          — Editor: render, keybinding dispatch, multi-view
│   ├── editor_ops.lua      — ← DELETED (absorbed into View)
│   ├── shared.lua           — SharedState: ring buffers, IO lane pointer, running flag
│   ├── shared_ffi.lua       — FFI cdef for SharedState
│   ├── buffer_ffi.lua       — FFI cdef for Buffer struct + POSIX
│   ├── tre_ffi.lua          — FFI cdef for TRE regex (extracted from editor_ops)
│   ├── keybind.lua          — (unchanged)
│   ├── default_keybindings.lua — receives view instead of editor
│   ├── ...
```

## Keybinding API Change

Old:
```lua
["ctrl-a"] = function(editor) editor:move_line_start() end
```

New:
```lua
["ctrl-a"] = function(view) view:move_line_start() end
```

Keybinding functions receive the active view. If they need the editor
(e.g., to quit, to access other views), they can call `view.editor`
or we can pass both: `function(view, editor)`.

## Open Questions

1. **IO lane handoff**: The user specified a void* field in SharedState.
   Alternative: send the mmap pointer through the ring buffer's `ptr` field.
   The void* field is simpler (no ring buffer message needed for the data,
   just a sentinel message to wake the main lane). Going with void* as specified.

2. **View: C struct vs pure Lua**: Pure Lua for now. If we need views across
   lanes in the future, we can add a C struct then. View fields are all scalars.

3. **filepath per-view vs per-editor**: With multi-file support, filepath should
   be per-view (each view knows which file its buffer came from). But the buffer
   itself shouldn't know about files — it just owns text. So filepath lives on View.

4. **Keybinding function signature**: `(view, editor)` — view for the common case,
   editor for the rare case (quit, save all).

5. **Cross-view edits**: Auto-close view A's group if view B starts editing.
   Prevents interleaved snapshots.

6. **Filepath per-Buffer**: Buffer knows its source file. Couples data to
   filesystem, but simpler for save.
