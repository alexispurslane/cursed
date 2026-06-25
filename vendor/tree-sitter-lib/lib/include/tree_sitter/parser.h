#ifndef TREE_SITTER_PARSER_H_
#define TREE_SITTER_PARSER_H_

/* Compatibility shim: older parsers include <tree_sitter/parser.h>,
 * modern tree-sitter ships <tree_sitter/api.h> as the single header.
 * api.h is a superset that includes all the scanner callback types. */

#include "api.h"

#endif /* TREE_SITTER_PARSER_H_ */
