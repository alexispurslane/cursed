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

- Both needed a vendored-termbox2 patch because the new style bits live above 32 bits — where LuaJIT's 32-bit `bit` library can't reach — so the 64-bit packing stays in C.
- Validation failed for tool "ask_user_question":
- Let me do the final smoke launch under a pty to confirm no runtime crash, then mark done:
- So `alt-e`/`ctrl-e` can't become prefixes without losing `forward_sentence`/`move_line_end`.
- Found 2 occurrences of edits[2] in /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua. Each oldText must be unique. Please provide more context to make it uni
- Now let me unit-test the pick/wrap logic (LLS can't catch runtime bugs there) with a standalone harness mirroring `jump_diagnostic` exactly:
- Now a smoke launch to confirm no runtime crash on module load:
- getting a crash now when I try to jump to a workspace symbol: double free

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua (9 reads) — Now the LSP symbol completers. Let me add a new section to completers.lua.
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua (4 reads) — Let me look at the LSP command section in commands.lua and the read_from_minibuf
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (10 reads) — Let me confirm `schedule_after` semantics (return value) and the `file_loaded` e
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/lsp_lane.lua (3 reads) — Let me verify the LSP lane relays arbitrary request methods generically (not jus
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (9 reads) — The highlighter is viewport-lazy and cold-query based. Let me look at how it ref
