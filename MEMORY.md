# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- we should do alt+q ig
- Let me fix the colors properly and use yellow for the footer hint.
- I realize the approach is getting overly complex.
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation
- ---
- Deadlines are in the future but the loop still iterates ~1540/sec — so `select` returns early every iteration (a ready fd).
- **`completer_requesting`** `{cid, line, character, prefix, trigger, reason}` — main decided to fire a request (reason = `first`/`trigger`/`pos_changed`/`prefix_grew`).
- let's create a manual trigger command, bound to M-/; we should also pull in and save the trigger chars from the LSP, and have those trigger completions *immediately*

## Gotchas & Errors

- cursed: failed to initialize terminal: cursed.tb: tb_init failed (code -4) — Fix: So when the user ran in their terminal, it should be too, unless...
- log` cannot be opened, so we'll get logs one way or another.
- === render item counts (chronological) === — Fix: Let me actually look at the damage-tracking / repaint logic, because for a ghost to *persist* (not just flicker for 4ms), the old box's cells must not be getting repainted frame-to-frame.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua. The old text must match exactly including all whitespace and newlines. — Fix: Let me re-apply the `_tick` fix there.
- Found 2 occurrences of the text in src/cursed/completers.lua. The text must be unique. Please provide more context to make it unique.
- Could not find edits[2] in src/cursed/completers.lua. The oldText must match exactly including all whitespace and newlines.
- Jul  2 18:37:25 2026 build/cursed
- While we wait, let me rule out a crash-on-launch or a stale binary (I rebuilt at 18:35):
