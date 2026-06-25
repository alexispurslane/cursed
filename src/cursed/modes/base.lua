--- Base major mode (built-in).
---
--- The catch-all default mode (no language → no highlighting).
--- Activated for every file via the `.*` pattern; language-specific
--- modes layer on top.

---@return MajorModeSpec
return {
    name = "base",
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
}
