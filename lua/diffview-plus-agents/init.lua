local M = {}

---User-facing plugin name used as the title on `vim.notify` popups so
---notify UIs like `rcarriga/nvim-notify` have something to render in the
---title slot. Core `vim.notify` ignores the opts table, so this is a
---no-op there.
local NOTIFY_TITLE = "diffview+agents"

local function notify(msg, level)
  vim.notify(msg, level, { title = NOTIFY_TITLE })
end

---Verify diffview-plus is loaded and prepare for later tool-specific
---integrations. Today a bare skeleton; follow-up commits wire the first
---tool's status column and pairing keymaps.
---@param _opts? table
function M.setup(_opts)
  local ok = pcall(require, "diffview.scene.views.worktree_overview.worktree_overview_view")
  if not ok then
    notify("diffview-plus.nvim must be installed and loaded first", vim.log.levels.ERROR)
    return
  end
end

return M
