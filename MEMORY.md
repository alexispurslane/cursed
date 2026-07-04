# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- I realize the approach is getting overly complex.
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation
- ---
- Deadlines are in the future but the loop still iterates ~1540/sec — so `select` returns early every iteration (a ready fd).
- **`completer_requesting`** `{cid, line, character, prefix, trigger, reason}` — main decided to fire a request (reason = `first`/`trigger`/`pos_changed`/`prefix_grew`).
- let's create a manual trigger command, bound to M-/; we should also pull in and save the trigger chars from the LSP, and have those trigger completions *immediately*
- The convention is clear: vendored as committed plain files in `vendor/tree-sitter-<lang>/src/` (markdown split into two dirs).
- whenever the user moves the cursor, we should keep track of the nearest diagnostic span (bias towards below) and, if the cursor is within that span, display the text of the diagnostic as a popup sort of like the...

## Gotchas & Errors

- Let me do the final smoke launch under a pty to confirm no runtime crash, then mark done:
- So `alt-e`/`ctrl-e` can't become prefixes without losing `forward_sentence`/`move_line_end`.
- Found 2 occurrences of edits[2] in /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua. Each oldText must be unique. Please provide more context to make it uni
- Now let me unit-test the pick/wrap logic (LLS can't catch runtime bugs there) with a standalone harness mirroring `jump_diagnostic` exactly:
- Now a smoke launch to confirm no runtime crash on module load:
- getting a crash now when I try to jump to a workspace symbol: double free
- Traceback (most recent call last):
- The lua "fail" is just a wrong test expectation — `local function baz() end` IS captured (the label includes the trailing `end` since the node is a one-liner).

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (5 reads) — Let me check the buffer's line text API and `set_single_cursor`, plus the `curre
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/lua.lua (3 reads) — Now run the outline test through the shim:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/ts.lua (5 reads) — Let me look at the ts API methods for extracting node text and ranges, plus the 
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua (7 reads) — Now let me look at the top of completers.lua for the helpers (`current_doc`, `bu
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (5 reads) — Now the editor.lua refactor. Let me read the full `place_cursor_lsp` context:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/major_mode.lua (3 reads) — Now run `just fmt` to fix the formatting in commands.lua, then `just check`:
