# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- oh shit, I just remembered, this is a big issue: we don't want to have to trash all the old parse trees, the TS parser we've loaded, and all state on every cross-language buffer...
- If that's awkward, an acceptable alternative: skip creating the initial empty view when args are present — but that touches earlier code; prefer the reuse approach to keep the diff...
- Prefer the approach that keeps the diff small and clearly correct.
- prefer the lexicographically-first chord, or the shortest — pick one and document it).

## Key Decisions

- path` is never set, so `require("external")` fails without manual coercion.
- we're still better than emacs in practice, because in practice we gain in general so much, even on edits, on various things, that our time/space complexity isn't an issue.
- However, we should actually probably do things differently in pratice --- I've reevaluated my idea.
- the callable table is obviously what we should do, and sort of what I had in mind.
- Let me split into two files:
- ** Roberto Ierusalimschy has said the design rule is roughly: if something can be done acceptably in userspace, it should not be in the core.
- - Slightly ad-hoc: the "read this child node's text as a label" rule is bespoke per node type.
- language` directive) → look up parser → `set_included_ranges([content_range])` → parse → `filtered_captures` over injected query → collect → merge into block captures.
- The query has `subscript subscript: (word) @field` — using `subscript` as both the node type *and* a field name.
- All injected captures (absolute byte offsets) merge into one sorted stream that `build_range_spans` runs the stack algorithm over, so bold-inside-a-heading and lua-inside-a-fence layer correctly.

## Gotchas & Errors

- Could not find edits[1] in src/cursed/modes/toml.lua. The oldText must match exactly including all whitespace and newlines. — Fix: Now I also need to check whether any *other* query files contain a literal `]==]` or `]]` but not `]]`...
- Net: "implementing predicates" is **not** blocked and **not** a library-upgrade problem — it's a contained, ~100-300 line feature depending on scope, against an API that's already cdef'd.
- " You then filter the match (drop it if predicates fail), and use its captures.
- ## One detail that matters for *us*
- Could not find edits[1] in src/cursed/highlight_lane.lua. The oldText must match exactly including all whitespace and newlines.
- ===== BUFFER METHODS =====
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/docs/future-work-report.md. The old text must match exactly including all whitespace and newlines.
- md` (both the §1/§2 listings and the cross-cutting section), noting the fix — the caret cell is now painted on wrapped non-first sub-rows (the original guard `csub_col < chunk_start` failed on any...
