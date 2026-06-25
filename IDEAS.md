# IDEAS

1. We should create a separate highlighter lua lane (like the current io lane) and allocate on the heap the relevant parts of the document text and line lengths (calculated on the main thread), then send a pointer to that to the highlighter lane (which is also responsible for freeing it when it's done, by wrapping it in a cffi gc reference). Then it should run `Highlighter:highlight()`, cursor:exec, build the spans, etc, then send a heap-allocated pointer to the spans back to the main lane.

2. The highlight lane should hold on to the old parse tree, use Tree:edit to increpmentally parse the document.

3. Caching should be managed by the main lane, in the sense that the main lane should store the spans returned from the highlighter lane, and determine when to message the highlighter lane next. When it does message the highlighter lane, it should display the old highlighter spans (if any) until it gets a message back, and then replace them.

4. We should do per-region bounded recomputation and re-querying, although I'd appreciate you explaining to me the prcise ins and outs of how that'd work before we do it, the basic idea I have in mind is that the region should be: from the cursor to 2x the viewport, in bytes, past the cursor, ignoring lines. And that's as far as we go. That way it works both vertically and for really long lines. We should then be able to remove the MAX_HL_BYTES machinery entirely. 
