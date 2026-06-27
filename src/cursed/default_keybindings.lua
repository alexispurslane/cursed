--- Default keybindings for the cursed editor.
---
--- Maps key chord specifier strings to command names (strings) or functions.
--- String values are resolved from the commands table at dispatch time.
--- The special `__printable` key handles unmodified printable characters.

return {
    --- Handler for unmodified printable characters.
    ["__printable"] = function(view, editor, ch)
        view:delete_selection()
        local n = 1
        if editor.universal_args then
            for i = 2, #editor.universal_args do
                local arg = editor.universal_args[i]
                local ty = type(arg)
                if ty == "number" then
                    n = n * arg
                elseif ty == "string" then
                    n = n * #arg
                end
            end
        end
        n = math.abs(n)
        for _ = 1, n do
            view:insert_char(ch)
        end
    end,

    -- Line navigation
    ["ctrl-a"] = "move_line_start",
    ["home"] = "move_line_start",
    ["ctrl-e"] = "move_line_end",
    ["end"] = "move_line_end",

    -- Character navigation
    ["ctrl-b"] = "backward_char",
    ["left"] = "backward_char",
    ["ctrl-f"] = "forward_char",
    ["right"] = "forward_char",

    -- Line navigation
    ["ctrl-p"] = "previous_line",
    ["up"] = "arrow_up",
    ["ctrl-n"] = "next_line",
    ["down"] = "arrow_down",

    -- Page navigation
    ["alt-v"] = "scroll_down",
    ["pageup"] = "scroll_down",
    ["ctrl-v"] = "scroll_up",
    ["pagedown"] = "scroll_up",

    -- Deletion
    ["ctrl-d"] = "delete_char",
    ["delete"] = "delete_char",
    ["backspace"] = "backward_delete_char",

    -- Newline / submit
    ["ctrl-j"] = "newline",
    ["enter"] = "enter_key",
    -- Shift+Enter inserts a newline. On modern terminals (Ghostty/xterm
    -- with formatOtherKeys, kitty CSI-u) this arrives as ESC[27;2;13~ /
    -- ESC[13;2u, now decoded to the "shift-enter" token by keybind.
    ["shift-enter"] = "newline",

    -- Tab: expand completion
    ["tab"] = "tab_key",

    -- Universal argument
    ["ctrl-u"] = "universal_argument",

    -- Eval
    ["alt-:"] = "eval_expression",

    -- Execute command
    ["alt-x"] = "execute_command",

    -- Word/sentence navigation
    ["alt-f"] = "forward_word",
    ["alt-b"] = "backward_word",
    ["alt-e"] = "forward_sentence",
    ["alt-a"] = "backward_sentence",
    ["alt-s"] = "forward_subsentence",
    ["alt-S"] = "backward_subsentence",

    -- Bigword (whitespace-delimited words: M-F / M-B)
    ["alt-F"] = "forward_bigword",
    ["alt-B"] = "backward_bigword",

    -- Paragraphs (Emacs: M-{ forward, M-} backward; note swapped here
    -- because M-{ and M-} require shift which lands on {[} on most layouts)
    ["alt-{"] = "forward_paragraph",
    ["alt-}"] = "backward_paragraph",

    -- Minibuffer history
    ["alt-p"] = "history_up",
    ["alt-n"] = "history_down",

    -- Recenter
    ["ctrl-l"] = "recenter",

    -- Search (C-s/C-r isearch unchanged; alt-% query-replace; regex
    -- isearch available via M-x isearch-forward-regexp / backward)
    ["ctrl-s"] = "isearch_forward",
    ["ctrl-r"] = "isearch_backward",
    ["alt-%"] = "query_replace",

    -- Kill / Open
    -- NOTE: C-w is remapped from backward-kill-word to kill-region
    -- (Emacs-faithful). backward-kill-word moves to M-<backspace>.
    ["ctrl-k"] = "kill_line",
    ["ctrl-o"] = "open_line",
    ["ctrl-w"] = "kill_region",
    ["alt-backspace"] = "kill_word",
    ["alt-d"] = "kill_word_forward",
    ["alt-k"] = "kill_sentence",
    ["ctrl-x delete"] = "backward_kill_sentence",
    ["ctrl-x ctrl-k"] = "kill_whole_line",
    ["ctrl-x alt-p"] = "kill_paragraph",

    -- Buffer navigation
    ["alt-<"] = "beginning_of_buffer",
    ["alt->"] = "end_of_buffer",

    -- Transpose
    ["ctrl-t"] = "transpose_chars",
    ["alt-t"] = "transpose_words",
    ["ctrl-x ctrl-t"] = "transpose_lines",
    ["ctrl-x alt-t"] = "transpose_sentences",

    -- Cancel
    ["ctrl-g"] = "keyboard_quit",
    ["ctrl-c"] = "quit",

    -- Mark / Selection
    ["ctrl-space"] = "set_mark",
    ["ctrl-x ctrl-x"] = "swap_mark_and_cursor",
    ["alt-@"] = "mark_word",
    ["alt-h"] = "mark_paragraph",
    ["ctrl-x h"] = "mark_whole_buffer",

    -- Multi-cursor
    ["ctrl-x ctrl-n"] = "select_next_match",
    ["ctrl-x ctrl-p"] = "select_prev_match",
    ["ctrl-x a"] = "select_all_matches",
    ["ctrl-x S"] = "split_selection_into_lines",
    ["alt-;"] = "add_cursor_here",
    ["alt-m"] = "commit_pending_cursors",
    ["alt-up"] = "add_cursor_up",
    ["alt-down"] = "add_cursor_down",

    -- Kill ring
    ["ctrl-y"] = "yank",
    ["alt-y"] = "yank_pop",
    -- ctrl-shift-y: termbox delivers ctrl+y (0x19) with TB_MOD_SHIFT set,
    -- producing token "shift-ctrl-y" which parse_chord cannot handle
    -- (shift-prefixed components must be named keys, not ctrl-letter combos).
    -- Not bound by default; set in init.lua if desired.
    ["alt-w"] = "copy_region",
    ["ctrl-x alt-w"] = "copy_sentence",

    -- Undo / Redo
    ["ctrl-_"] = "undo",
    ["ctrl-x u"] = "undo",
    ["ctrl-x r"] = "redo",
    ["ctrl-x alt-u"] = "undo_in_selection",
    ["ctrl-x alt-r"] = "redo_in_selection",

    -- Case changes
    ["alt-u"] = "upcase_word",
    ["alt-l"] = "downcase_word",
    ["alt-c"] = "capitalize_word",
    ["ctrl-x ctrl-u"] = "upcase_region",
    ["ctrl-x ctrl-l"] = "downcase_region",
    ["ctrl-x _"] = "snake_case_region",
    ["ctrl-x -"] = "kebab_case_region",
    ["ctrl-x c"] = "camelcase_region",
    ["ctrl-x t"] = "title_case_region",
    ["ctrl-x space"] = "remove_spaces_region",

    -- Whitespace / line joining
    ["alt-\\"] = "delete_horizontal_space",
    ["alt-space"] = "just_one_space",
    ["ctrl-x ctrl-o"] = "delete_blank_lines",
    ["alt-^"] = "delete_indentation",

    -- Quoted insert + zap-to-char
    ["ctrl-q"] = "quoted_insert",
    ["alt-z"] = "zap_to_char",
    ["alt-Z"] = "zap_up_to_char",

    -- Balanced-expression (sexp) commands. Emacs binds these to C-M-*,
    -- which terminals can't deliver reliably, so they live under the
    -- C-x s prefix. (split_selection_into_lines was moved to C-x S so
    -- it no longer shadows the C-x s <x> sexp chords — the trie
    -- dispatches immediately on a complete node match, so a binding on
    -- C-x s alone would swallow every longer C-x s * chord.)
    ["ctrl-x s m"] = "mark_sexp",
    ["ctrl-x s k"] = "kill_sexp",
    ["ctrl-x s w"] = "copy_sexp",
    ["ctrl-x s t"] = "transpose_sexp",
    ["ctrl-x s f"] = "forward_sexp",
    ["ctrl-x s b"] = "backward_sexp",
    ["ctrl-x s d"] = "down_list",
    ["ctrl-x s u"] = "up_list",
    ["ctrl-x s alt-u"] = "backward_up_list",

    -- File / Buffer
    ["ctrl-x ctrl-f"] = "find_file",
    ["ctrl-x i"] = "insert_file",
    ["ctrl-x ctrl-w"] = "save_as",
    ["ctrl-x b"] = "ibuffer",
    ["ctrl-x k"] = "kill_buffer",
    ["ctrl-x ctrl-s"] = "save",
    ["ctrl-x ctrl-c"] = "quit",

    -- Keyboard macros
    ["ctrl-x ("] = "start_kmacro",
    ["ctrl-x )"] = "end_kmacro",
    ["ctrl-x e"] = "run_kmacro",

    -- Repeat: rerun the last command (C-x z, then `z` to keep repeating)
    ["ctrl-x z"] = "repeat",

    -- Goto line
    ["alt-g"] = "goto_line",

    -- Escape
    ["escape"] = "escape_key",
}
