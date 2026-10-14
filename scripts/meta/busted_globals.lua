---@meta

-- Under `plenary.nvim`'s Busted runner, the global `assert` is replaced
-- with a Luassert instance. This stub retypes the global so LuaLS
-- resolves `assert.equals`, `assert.is_nil`, etc. in spec files that do
-- not locally `require("luassert")`.
--
-- Only consumed by LuaLS via `workspace.library` in `.luarc.json`. The
-- assignment is `assert = assert` rather than `assert = nil` so that, if
-- this file is ever loaded at runtime by mistake, it cannot clobber the
-- real `assert` global; LuaLS still picks up the type from `---@type`.

---@type Luassert
assert = assert
