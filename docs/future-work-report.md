# Cursed — Future Work Report

## Status Legend

- **Planned** — wanted, ready to implement or scoped later
- **Blocked** — wanted but requires a prerequisite
- **Deferred** — wanted, intentionally queued for later

---

## LSP Protocol

The client currently supports 6 of ~30+ LSP request types: completion, hover, goto-definition, formatting, publishing diagnostics, and file open/change/close notifications. The following are all desired but missing:

### Planned

1. **`textDocument/codeAction`** — Request available code actions at/before the cursor, show them in a completion-like minibuffer menu, and apply the selected action via `workspace/applyEdit`. Requires nothing structural beyond adding the request in `lsp_client.lua`, routing it through the LSP lane, and a command in `commands.lua` that mirrors the existing `goto_definition` async callback pattern.
   - *Blocker for:* gutter-based action icons (blocked on a generalized gutter system — see next section)
   
2. **`textDocument/rename`** — Rename symbol at cursor. Requires `request_rename()`, `prepareRename()` (to catch unsupported positions), and applying the single-edit workspace edit result to the buffer as one undo group.

3. **`textDocument/references`** — Find all references at cursor. Same async request→callback pattern as goto-definition, but returns a list of locations. Should reuse `Editor:jump_to_location` to navigate into any target buffer.

4. **`textDocument/signatureHelp`** — Signature help popup (parameter hints for function calls). Should animate the in-buffer completion popup or use a floating overlay. Triggered by `triggerCharacter` chars on `sync_change` and explicit command.

5. **`textDocument/implementation`** — Jump to implementation (complement of go-to-definition, like vim's `gI`).

6. **`textDocument/typeDefinition`** — Jump to type definition (complement of go-to-definition).

7. **`textDocument/inlayHint`** — Inlay hints (parameter names on call sites, inferred types). Requires:
   - `request_inlay_hints()` in `lsp_client.lua`
   - Handling a new notification type or a `textDocument/inlayHint/refresh` mechanism
   - Rendering them via the overlay system (file-anchored overlays positioned inline with the text)

8. **`textDocument/documentLink` + `textDocument/documentLink/resolve`** — Clickable links in markdown, TML, JSON, etc. Overlay-rendered underlines + hover for link URLs.

### Blocked

9. **`textDocument/codeAction`** gutter icons — blocked on a generalized gutter overlay system. A gutter column needs: per-line anchoring at the start of visible text (before scroll offset), ability to render small glyphs/icons, and hit-testing to click actions.

---

## Convenience & Auto-Save

### Planned (save for later)

10. **Auto-save** — Save active buffers automatically at intervals or on events (buffer focus change, lose focus, idle timeout). Should be wired via `editor.event_system` listeners (`view_blur`, `buffer_focus`) or a scheduled background task with idle detection. User-configurable via `init.lua`: interval in seconds, save-on events, or disable entirely.

### Deferred

11. **Find-files-in-directory** — Recursively list files in the current directory or workspace root, show in minibuffer with file-tree completion, open on Enter. Complements the existing `find_file` (which opens one path) with a browsing interface analogous to `helm-find-files` / `fzf`.

### Rejected / Not desired

12. **Virtual spaces** — Intentionally not needed.
13. **Auto-close bracket navigation** — Intentionally not needed.
14. **New file command** — `find_file` on a non-existent path already works, though a dedicated `C-x C-n` command would be nice. Deferred.

---

## View, Line Numbers & Indent Guides

### Planned

15. **Move indent guides to overlays** — Indent guides should be implemented as file-anchored overlays (like diagnostics) rather than baked into the renderer. This keeps the core renderer simple, makes guides themeable via the colorscheme concept system, and follows the pattern already established for diagnostics and floating popups. Requires:
   - Detecting meaningful indent boundaries via tree-sitter node ranges or whitespace-based analysis
   - Emitting overlay calls per-line in a `render_overlay` event listener
   - Configurable style (thin/dashed/full-line, concept from colorscheme)

16. **Line numbers** — Already present in some form; verify they're cleanly rendered and configurable (absolute vs relative, concept from colorscheme). If they exist as baked-in renderer logic, migrate to overlay-based rendering too for consistency with indent guides.

---

## File Management

### Deferred

17. **Search across files** — Project-wide text search using ripgrep or similar. Requires the planned subprocess management lane. Equivalent of `helm-grep` / `rg --glob` integration.

---

## Architecture Prerequisites

These don't exist yet but are needed for several of the above:

18. **Subprocess management lane** — A dedicated thread/lane for spawning and managing external processes (grep, ripgrep, language tooling). Needed by: find-files-in-directory, project-wide grep, and any future LSP-adjacent tooling.

19. **Gutter overlay system** — A per-line rendering surface before the main text buffer. Needed by: code action icons in gutter, and potentially by line numbers and indent guides if they need wider than a single cell.

---

## Summary by Effort

| Effort | Work |
|--------|------|
| Low | `textDocument/rename`, `textDocument/references` — same pattern as goto-definition |
| Low-Medium | `textDocument/signatureHelp` — reuses completion popup or overlay |
| Medium | `textDocument/inlayHints` — overlay rendering + request protocol |
| Medium | `textDocument/documentLink` — overlay underlines + hover |
| Medium | `textDocument/codeAction` — completion menu + applyEdit handling |
| Medium | Auto-save — event listener or background task |
| Medium | Move indent guides to overlays |
| Medium | Indent guide overlay implementation |
| Medium | Find-files-in-directory |
| Medium+ | Gutter overlay system |
| | Subprocess management lane |
