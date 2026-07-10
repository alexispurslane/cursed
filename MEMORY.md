# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- when we expand _fm_dir, we should jump the cursor, if it was in the header to begin with, to the end of _fm_dir
- when the user deletes the trailing slash on _fm_dir, we should allow that, so it's easier to delete past into the directory name behind it
- I'll use 24-29 for the FILE ops.
- alright, now let's use those methods for all existing file ops in the editor that didn't already use the io lane
- We agreed earlier to defer MSG_FILE_READ_BUFFER (a structured success reply) until we settled the response-model pattern, and the same gap exists here for writes.
- I think we should have the file io lane wrapper (on the main thread) store a module-global file op counter, not just slap it on Editor
- We agreed earlier that this gap exists, and deferred adding `MSG_FILE_READ_BUFFER` until we settle the response-model pattern.
- , the architecture should already have that, and we should make it happen.
- Actually the LOOP at `_take_file_op` is already keyed by req_id; if it's the same as the FIFO head, we should remove from FIFO too.
- Let me fix — only call `editor:open_file` if there's no current view, OR refactor to set the existing view's filepath + push with req_id.

## Gotchas & Errors

- Command aborted
- Good idea in principle — but I can't actually launch subagents from here.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/lua.lua. The old text must match exactly including all whitespace and newlines.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/rust.lua. The old text must match exactly including all whitespace and newlines.
- (no output)
- Validation failed for tool "edit": — Fix: Let me fix this in two separate calls — first fix `_paint_run`, then fix its call site:
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua. The old text must match exactly including all whitespace and newlines.
- Found 2 occurrences of the text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/file_manager.lua. The text must be unique. Please provide more context to make it uni

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (17 reads) — Three big chunks — let me plan them out before writing code. I'll batch-read wha
- /Users/alexispurslane/Development/scratch/cursed/src/shared_state.h (3 reads) — Free values: 17 is taken (LSP_NOTIFICATION), 18-22 taken (PROC), 23 taken (LSP_S
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/io_lane.lua (19 reads) — OK so the C header has number gaps (5,6,7 reserved and SHUTDOWN uses 5; FILE_INS
- /Users/alexispurslane/Development/scratch/cursed/src/main.lua (26 reads) — Now wire `MSG_FILE_DIRLIST_RESP` into main.lua's `drain_inbox`, and rewire `MSG_
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/shared_ffi.lua (4 reads) — Task #1 is still in progress. Let me finish it: the C header now has the new con
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/shared.lua (5 reads) — Ok. Moving the counter to a module-global. Let me find where to put it — probabl
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/buffer.lua (7 reads) — `Buffer.from_mmap` requires the data to be mmap'd (the GC guard calls `munmap`).
