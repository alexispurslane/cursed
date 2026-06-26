--- Markdown major mode (built-in).
---
--- Uses the tree-sitter-markdown SPLIT-PARSER design: the block grammar
--- parses document structure (headings, lists, code blocks, blockquotes).
--- An `injection_query` then walks the block tree for content regions
--- that belong to ANOTHER grammar, and the lane parses each region with
--- that grammar, merging its captures with the block captures. This
--- covers both fixed-language regions (inline nodes → markdown_inline,
--- metadata blocks → yaml/toml, html blocks → html) and the label-driven
--- `` ```lua `` fenced code block case (the `info_string`'s `language`
--- label names the grammar to use). See `cursed.highlight_lane`.

-- Block query: document structure (from upstream highlights.scm, trimmed).
-- Captures on `inline` children of headings make heading text read as
-- @text.title; the inline grammar (injected over inline regions) then
-- layers span styling (bold/italic/code) on top via the merged stream.
local MARKDOWN_HIGHLIGHT_QUERY = [[
(atx_heading
  (inline) @text.title)

(setext_heading
  (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

[
  (indented_code_block)
  (fenced_code_block)
] @text.literal

(fenced_code_block_delimiter) @punctuation.delimiter

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation.special

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

(backslash_escape) @string.escape
]]

-- Inline query (for the markdown_inline grammar, injected over inline
-- content regions): bold/italic/code spans, links.
local MARKDOWN_INLINE_HIGHLIGHT_QUERY = [[
[
  (code_span)
  (link_title)
] @text.literal

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

(emphasis) @text.emphasis

(strong_emphasis) @text.strong

[
  (link_destination)
  (uri_autolink)
] @text.uri

[
  (link_label)
  (link_text)
  (image_description)
] @text.reference

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(shortcut_link
  [
    "["
    "]"
  ] @punctuation.delimiter)
]]

-- Injection query: walks the block tree for content regions belonging to
-- another grammar. Each pattern captures @injection.content (the byte
-- range to parse with the injected grammar) and either names the grammar
-- via #set! injection.language (the fixed cases) or via the
-- @injection.language capture (the fenced-code-block-label case, where
-- the language comes from the fence's info_string label text). The lane
-- looks up each resolved language in its injected-grammar table.
local MARKDOWN_INJECTION_QUERY = [[
; Fenced code block — language is DYNAMIC, read from the info_string.
; The @injection.language capture's text names the grammar (lua, python, …).
(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

; Inline prose — always markdown_inline (fixed by node type).
((inline) @injection.content
 (#set! injection.language "markdown_inline"))

; YAML front matter (--- delimited).
((minus_metadata) @injection.content
 (#set! injection.language "yaml"))

; TOML front matter (+++ delimited).
((plus_metadata) @injection.content
 (#set! injection.language "toml"))

; Raw HTML block — always html.
((html_block) @injection.content
 (#set! injection.language "html"))
]]

---@return MajorModeSpec
return {
    name = "markdown",
    language = "markdown",
    highlight_query = MARKDOWN_HIGHLIGHT_QUERY,
    injection_query = MARKDOWN_INJECTION_QUERY,
    -- markdown_inline has no MajorMode of its own (it's only ever
    -- injected by markdown's injection query), so the markdown mode
    -- supplies its highlight query directly.
    extra_injected_grammars = {
        markdown_inline = MARKDOWN_INLINE_HIGHLIGHT_QUERY,
    },
    tab_width = 2,
    margin = 72,
    expand_tab = true,
    indent_width = 2,
}
