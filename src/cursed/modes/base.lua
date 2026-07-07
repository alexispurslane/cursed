--- Base major mode (built-in).
---
--- The catch-all default mode (no language → no highlighting).
--- Activated for every file via the `.*` pattern; language-specific
--- modes layer on top.

---@return MajorModeSpec
return {
    name = "base",
}
