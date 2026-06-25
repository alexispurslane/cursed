/* vendor.h — bundled third-party declarations
 *
 * tree-sitter: each parser exports a single function
 *   const TSLanguage *tree_sitter_<lang>(void);
 * termbox2: included as header-only with TB_IMPL
 */
#ifndef VENDOR_H
#define VENDOR_H

/* tree-sitter API + parser declarations */
#include <tree_sitter/api.h>

const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_go(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_lua(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_toml(void);
const TSLanguage *tree_sitter_yaml(void);

/* termbox2 — header-only, compiled via termbox2_impl.c with TB_IMPL */

#endif /* VENDOR_H */
