# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- Let me fix the colors properly and use yellow for the footer hint.
- I realize the approach is getting overly complex.
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation
- ---
- Deadlines are in the future but the loop still iterates ~1540/sec — so `select` returns early every iteration (a ready fd).
- **`completer_requesting`** `{cid, line, character, prefix, trigger, reason}` — main decided to fire a request (reason = `first`/`trigger`/`pos_changed`/`prefix_grew`).
- let's create a manual trigger command, bound to M-/; we should also pull in and save the trigger chars from the LSP, and have those trigger completions *immediately*
- The convention is clear: vendored as committed plain files in `vendor/tree-sitter-<lang>/src/` (markdown split into two dirs).

## Gotchas & Errors

- While we wait, let me rule out a crash-on-launch or a stale binary (I rebuilt at 18:35):
- 477:            log.info("lsp_complete", "needreq_debug", {
- sed: ../talkai/src/lib/api.ts: No such file or directory
- ls: ../talkai/src/lib/api.ts: No such file or directory
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua. The old text must match exactly including all whitespace and newlines.
- Found 2 occurrences of the text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua. The text must be unique. Please provide more context to make it uniqu
- ` fails before `super()` but works after
- TypeScript has a hard rule: in a derived-class constructor body, **before the `super()` call**, `this` is uninitialized — you cannot reference `this`, return, or access instance state there.
