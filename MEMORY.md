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

- TypeScript has a hard rule: in a derived-class constructor body, **before the `super()` call**, `this` is uninitialized — you cannot reference `this`, return, or access instance state there.
- Could not find edits[4] in src/cursed/view.lua. The oldText must match exactly including all whitespace and newlines.
- Could not find edits[3] in src/cursed/view.lua. The oldText must match exactly including all whitespace and newlines.
- === request_full_damage refs ===
- (no output)
- The earlier multi-edit failed atomically, so edits 1,2,3,5,6,7 didn't apply.
- Command exited with code 1 — Fix: The key result: **before** the fix, line 45 serialized as `super(message);        ` (no newline split); **after**, it correctly splits.
- === DIFF after Enter at end of line 45 === — Fix: Let me verify the `993a995` EOF blank is pre-existing (not from my fix) and check cursor behavior:

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/buffer.lua (4 reads) — The log is revealing! `after_len: 23` and `after_text: "        super(message);"
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (8 reads) — The bare buffer call is correct, so the editor's surrounding machinery (hooks, h
