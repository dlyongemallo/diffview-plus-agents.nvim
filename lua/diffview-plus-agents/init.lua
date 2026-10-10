local M = {}

---User-facing plugin name used as the title on `vim.notify` popups so
---notify UIs like `rcarriga/nvim-notify` have something to render in the
---title slot. Core `vim.notify` ignores the opts table, so this is a
---no-op there.
local NOTIFY_TITLE = "diffview+agents"

local function notify(msg, level)
  vim.notify(msg, level, { title = NOTIFY_TITLE })
end

---@class DiffviewPlusAgentsConfig
---@field sidekick? table # Opt-in sidekick.nvim integration. Pass `{}` to enable with defaults; omit to disable.

---Status provider currently registered on the overview, if any. Kept so a
---second `setup()` call unregisters the previous one before installing the
---new one; otherwise reloading the plugin would stack providers.
---@type (fun(entry: GitAdapter.WorktreeEntry, done: fun(result: string?)))?
M._status_provider = nil

---Wire each supported tool's status column into diffview-plus's worktree
---overview. Today sidekick.nvim is the only tool; its block opts into
---the `<glyph><tool-name>` column rendered next to each worktree row.
---Calling `setup()` again replaces the previous registration cleanly.
---@param opts? DiffviewPlusAgentsConfig
function M.setup(opts)
  opts = opts or {}

  local ok, overview =
    pcall(require, "diffview.scene.views.worktree_overview.worktree_overview_view")
  if not ok then
    notify("diffview-plus.nvim must be installed and loaded first", vim.log.levels.ERROR)
    return
  end

  if M._status_provider then
    overview.unregister_status_provider(M._status_provider)
    M._status_provider = nil
  end

  if opts.sidekick then
    local status = require("diffview-plus-agents.providers.sidekick").setup(opts.sidekick)
    overview.register_status_provider(status)
    M._status_provider = status
  end
end

return M
