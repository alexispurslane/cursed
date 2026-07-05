# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- go with alt-' for expand, and we'll use alt-" for collapse in the future.
- Since the AGENTS rule is "Run `just check`.
- , the convention is "end at col 0 of the next line" (half-open across lines).
- Actually, the simplest robust fix: in the C cleanup, when the main return code indicates a headless exit, use `pthread_cancel` instead of `pthread_join` for the lanes.
- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...
- The command may use tree-sitter as a fallback rather than LSP.
- for instance, we should probably add ctrl-c s and ctrl-c k for starting and killing the lsp, and maybe ctrl-c ctrl-r for restarting it.
- alright, now, we should make LSP notifications and responses come back as events on the event bus, instead of having to have this whole separate "mint callback, store it, call it" thing.

## Gotchas & Errors

- )` — `(stream, bytes)` where stream is `"stdout"`/`"stderr"`, or `(kind, code)` where kind is `"exited"`/`"signaled"`/`"failed"`/`"kill_sent"`.
- Command aborted
- === Pane ===
- usage: cursed [-e EXPR | -l MODULE]... [FILE...]
- The listener surfaces the spawn settle as a status message: `"language server ready (X)"` / `"not on PATH (X)"` / `"failed to start (X)"` / `"stopped (X)"`.
- stylua --check src — Fix: The new one is `_code_action_lines_by_uri` — I need to add a field annotation.
- stylua --check src
- vendor/luajit/src/luajit: /tmp/vp_test.lua:33: attempt to call method 'line_count' (a nil value)

## Heavily Read

- src/main.lua (3 reads) — Let me find the main loop itself.
- src/cursed/editor.lua (10 reads) — Let me look at `tick_background_tasks`, `next_task_deadline`, `minibuffer_notify
- src/cursed/editor_listeners.lua (7 reads) — Let me look at the editor_listeners `post_command_hook` and `ring_buffer_message
- src/cursed/completion_menu.lua (6 reads) — Let me see the full `close()`, `_on_post_command`, `handle_key`, and `_tick` to 
- src/cursed/overlay.lua (4 reads) — The diagnostic squiggle painter queues `put_underline` for every diagnostic rang
- src/cursed/view.lua (10 reads) — The mechanism is clear:
