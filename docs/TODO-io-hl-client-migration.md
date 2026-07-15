# TODO: Move IO/HL wrapper functions to their lane clients

## IO Lane

Currently, `editor.lua` contains ~20 methods that push directly to the IO lane
(`ss:push(ss._ptr.outboxes[LANE_IDX_IO], ...)`) and register one-shot event
handlers for `file_op:<req_id>` replies. Examples:
- `open_file`, `save_file`, `create_file`, `delete_file`, `mkdir`
- `rename_file`, `chmod_file`, `dirlist_async`, `write_file`
- `load_file_into_buffer`, `insert_file_contents`, etc.

These should move to `src/cursed/io_client.lua`, which currently only has
`setup` and `reinitialize`. The moved methods should:
- Take `(editor, ...)` as parameters (matching current signatures)
- Call `editor:track_pending_op(LANE_IDX_IO, req_id)` before push
- Register one-shot `file_op:<req_id>` handlers that call
  `editor:clear_pending_op(LANE_IDX_IO, req_id)`
- Be exposed as `editor.io.open(...)`, `editor.io.save(...)`, etc.
  instead of `editor:open_file(...)`, `editor:save_file(...)`.

This keeps editor.lua focused on state/view management and gives the IO
client a complete, testable surface with proper pending-op tracking.

## HL Lane

Similarly, highlight-related methods in `view.lua` (like `_hl_request_spans`,
`hl_reinitialize`, `_rebuild_highlighter`) could move to `hl_client.lua`.
The client would own the full highlight request lifecycle and the view
would delegate to it.

## Priority

Low — the current architecture works. This is a code-organization
improvement, not a functional requirement. Do it when touching these
areas for other reasons.
