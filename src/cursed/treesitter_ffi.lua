--- Tree-sitter FFI bindings for LuaJIT.
---
--- Declares the tree-sitter C API functions via ffi.cdef,
--- then returns ffi.C so callers can invoke C functions directly.
--- The safe RAII wrapper is in `cursed.ts`.
---
--- Memory lifecycle:
---   TSParser  — create with ts_parser_new(), free with ts_parser_delete()
---   TSTree    — create from parse, free with ts_tree_delete()
---   TSNode    — value type (copy by value, no free needed)
---   TSQuery   — create with ts_query_new(), free with ts_query_delete()
---   TSQueryCursor — create with ts_query_cursor_new(), free with ts_query_cursor_delete()
---
--- RAII wrappers that handle cleanup are in `cursed.ts`.

local ffi = require("ffi")

-- Standard libc — needed for freeing malloc'd strings from ts_node_string etc.
ffi.cdef([[
void free(void *ptr);
]])

ffi.cdef([[
/* ── tree-sitter API (v0.26, ABI 15) ─────────────────────────────────── */

typedef uint16_t TSStateId;
typedef uint16_t TSSymbol;
typedef uint16_t TSFieldId;
typedef struct TSLanguage TSLanguage;
typedef struct TSParser TSParser;
typedef struct TSTree TSTree;
typedef struct TSQuery TSQuery;
typedef struct TSQueryCursor TSQueryCursor;

typedef enum TSInputEncoding {
    TSInputEncodingUTF8,
    TSInputEncodingUTF16LE,
    TSInputEncodingUTF16BE,
    TSInputEncodingCustom
} TSInputEncoding;

typedef enum TSSymbolType {
    TSSymbolTypeRegular,
    TSSymbolTypeAnonymous,
    TSSymbolTypeSupertype,
    TSSymbolTypeAuxiliary
} TSSymbolType;

typedef struct TSPoint {
    uint32_t row;
    uint32_t column;
} TSPoint;

typedef struct TSRange {
    TSPoint start_point;
    TSPoint end_point;
    uint32_t start_byte;
    uint32_t end_byte;
} TSRange;

typedef struct TSInput {
    void *payload;
    const char *(*read)(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read);
    TSInputEncoding encoding;
    void *decode;  /* TSDecodeFunction — omit full signature, we use UTF8 only */
} TSInput;

typedef struct TSInputEdit {
    uint32_t start_byte;
    uint32_t old_end_byte;
    uint32_t new_end_byte;
    TSPoint start_point;
    TSPoint old_end_point;
    TSPoint new_end_point;
} TSInputEdit;

typedef struct TSNode {
    uint32_t context[4];
    const void *id;
    const TSTree *tree;
} TSNode;

typedef struct TSTreeCursor {
    const void *tree;
    const void *id;
    uint32_t context[3];
} TSTreeCursor;

typedef struct TSQueryCapture {
    TSNode node;
    uint32_t index;
} TSQueryCapture;

typedef enum TSQuantifier {
    TSQuantifierZero = 0,
    TSQuantifierZeroOrOne,
    TSQuantifierZeroOrMore,
    TSQuantifierOne,
    TSQuantifierOneOrMore
} TSQuantifier;

typedef struct TSQueryMatch {
    uint32_t id;
    uint16_t pattern_index;
    uint16_t capture_count;
    const TSQueryCapture *captures;
} TSQueryMatch;

typedef enum TSQueryPredicateStepType {
    TSQueryPredicateStepTypeDone,
    TSQueryPredicateStepTypeCapture,
    TSQueryPredicateStepTypeString
} TSQueryPredicateStepType;

typedef struct TSQueryPredicateStep {
    TSQueryPredicateStepType type;
    uint32_t value_id;
} TSQueryPredicateStep;

typedef enum TSQueryError {
    TSQueryErrorNone = 0,
    TSQueryErrorSyntax,
    TSQueryErrorNodeType,
    TSQueryErrorField,
    TSQueryErrorCapture,
    TSQueryErrorStructure,
    TSQueryErrorLanguage
} TSQueryError;

/* ── Parser ────────────────────────────────────────────────────────────── */

TSParser *ts_parser_new(void);
void ts_parser_delete(TSParser *self);
const TSLanguage *ts_parser_language(const TSParser *self);
bool ts_parser_set_language(TSParser *self, const TSLanguage *language);

bool ts_parser_set_included_ranges(
    TSParser *self,
    const TSRange *ranges,
    uint32_t count
);

const TSRange *ts_parser_included_ranges(
    const TSParser *self,
    uint32_t *count
);

TSTree *ts_parser_parse(
    TSParser *self,
    const TSTree *old_tree,
    TSInput input
);

TSTree *ts_parser_parse_string(
    TSParser *self,
    const TSTree *old_tree,
    const char *string,
    uint32_t length
);

void ts_parser_reset(TSParser *self);

/* ── Tree ──────────────────────────────────────────────────────────────── */

TSTree *ts_tree_copy(const TSTree *self);
void ts_tree_delete(TSTree *self);
TSNode ts_tree_root_node(const TSTree *self);
const TSLanguage *ts_tree_language(const TSTree *self);
void ts_tree_edit(TSTree *self, const TSInputEdit *edit);

TSRange *ts_tree_get_changed_ranges(
    const TSTree *old_tree,
    const TSTree *new_tree,
    uint32_t *length
);

/* ── Node ──────────────────────────────────────────────────────────────── */

const char *ts_node_type(TSNode self);
TSSymbol ts_node_symbol(TSNode self);
uint32_t ts_node_start_byte(TSNode self);
TSPoint ts_node_start_point(TSNode self);
uint32_t ts_node_end_byte(TSNode self);
TSPoint ts_node_end_point(TSNode self);
bool ts_node_is_null(TSNode self);
bool ts_node_is_named(TSNode self);
bool ts_node_is_missing(TSNode self);
bool ts_node_is_extra(TSNode self);
bool ts_node_has_changes(TSNode self);
bool ts_node_has_error(TSNode self);
bool ts_node_is_error(TSNode self);

TSNode ts_node_parent(TSNode self);
TSNode ts_node_child(TSNode self, uint32_t child_index);
uint32_t ts_node_child_count(TSNode self);
TSNode ts_node_named_child(TSNode self, uint32_t child_index);
uint32_t ts_node_named_child_count(TSNode self);

TSNode ts_node_child_by_field_name(
    TSNode self,
    const char *name,
    uint32_t name_length
);

TSNode ts_node_next_sibling(TSNode self);
TSNode ts_node_prev_sibling(TSNode self);
TSNode ts_node_next_named_sibling(TSNode self);
TSNode ts_node_prev_named_sibling(TSNode self);

TSNode ts_node_descendant_for_byte_range(TSNode self, uint32_t start, uint32_t end);
TSNode ts_node_named_descendant_for_byte_range(TSNode self, uint32_t start, uint32_t end);

char *ts_node_string(TSNode self);

void ts_node_edit(TSNode *self, const TSInputEdit *edit);
bool ts_node_eq(TSNode self, TSNode other);

/* ── TreeCursor ────────────────────────────────────────────────────────── */

TSTreeCursor ts_tree_cursor_new(TSNode node);
void ts_tree_cursor_delete(TSTreeCursor *self);
void ts_tree_cursor_reset(TSTreeCursor *self, TSNode node);
TSNode ts_tree_cursor_current_node(const TSTreeCursor *self);
const char *ts_tree_cursor_current_field_name(const TSTreeCursor *self);
bool ts_tree_cursor_goto_parent(TSTreeCursor *self);
bool ts_tree_cursor_goto_next_sibling(TSTreeCursor *self);
bool ts_tree_cursor_goto_first_child(TSTreeCursor *self);
int64_t ts_tree_cursor_goto_first_child_for_byte(TSTreeCursor *self, uint32_t goal_byte);

/* ── Query ─────────────────────────────────────────────────────────────── */

TSQuery *ts_query_new(
    const TSLanguage *language,
    const char *source,
    uint32_t source_len,
    uint32_t *error_offset,
    TSQueryError *error_type
);

void ts_query_delete(TSQuery *self);
uint32_t ts_query_pattern_count(const TSQuery *self);
uint32_t ts_query_capture_count(const TSQuery *self);
const char *ts_query_capture_name_for_id(
    const TSQuery *self,
    uint32_t index,
    uint32_t *length
);

/* String constants referenced by predicate steps (the operator name,
 * e.g. "eq?", and string-literal arguments). value_id indexes into
 * the same string table the query compiled its string literals into. */
const char *ts_query_string_value_for_id(
    const TSQuery *self,
    uint32_t id,
    uint32_t *length
);

/* Predicates for a pattern, as a flat TSQueryPredicateStep array
 * terminated by a Done step; multiple predicates are concatenated
 * (each one also ends with Done). The C library does NOT evaluate
 * predicates — the caller (us) interprets these steps. */
const TSQueryPredicateStep *ts_query_predicates_for_pattern(
    const TSQuery *self,
    uint32_t pattern_index,
    uint32_t *step_count
);

TSQueryCursor *ts_query_cursor_new(void);
void ts_query_cursor_delete(TSQueryCursor *self);
void ts_query_cursor_exec(TSQueryCursor *self, const TSQuery *query, TSNode node);
bool ts_query_cursor_next_match(TSQueryCursor *self, TSQueryMatch *match);
bool ts_query_cursor_next_capture(
    TSQueryCursor *self,
    TSQueryMatch *match,
    uint32_t *capture_index
);

bool ts_query_cursor_set_byte_range(
    TSQueryCursor *self,
    uint32_t start_byte,
    uint32_t end_byte
);

/* ── Language ──────────────────────────────────────────────────────────── */

uint32_t ts_language_symbol_count(const TSLanguage *self);
const char *ts_language_symbol_name(const TSLanguage *self, TSSymbol symbol);
TSSymbolType ts_language_symbol_type(const TSLanguage *self, TSSymbol symbol);
uint32_t ts_language_abi_version(const TSLanguage *self);
const char *ts_language_name(const TSLanguage *self);

/* ── Bundled parser entry points ──────────────────────────────────── */

const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_lua(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_markdown_inline(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_toml(void);
const TSLanguage *tree_sitter_yaml(void);
]])

return ffi.C
