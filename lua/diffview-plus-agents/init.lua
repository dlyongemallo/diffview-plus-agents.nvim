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
---@field sidekick? DiffviewPlusAgents.Sidekick.Config|table # Opt-in sidekick.nvim integration. Pass `{}` to enable with defaults; omit to disable both the status column and the pairing keymaps.

---Status provider currently registered on the overview, if any. Kept so a
---second `setup()` call unregisters the previous one before installing the
---new one; otherwise reloading the plugin would stack providers.
---@type (fun(entry: GitAdapter.WorktreeEntry, done: fun(result: string?)))?
M._status_provider = nil

---Enable or disable each supported tool's integration with diffview+'s
---worktree overview. Today sidekick.nvim is the only tool; its block
---opts into both the status column (`<glyph><tool-name>` next to each
---worktree row) and the pairing keymaps (`<CR>` auto-show, focus, send).
---Calling `setup()` again replaces the previous registration cleanly.
---@param opts? DiffviewPlusAgentsConfig
function M.setup(opts)
  opts = opts or {}

  -- Verify diffview-plus has actually been loaded, not just that its
  -- modules are reachable on `runtimepath`. A lazy-loaded diffview whose
  -- `plugin/diffview.lua` has not been sourced yet would still satisfy
  -- `pcall(require, ...)` while leaving `DiffviewGlobal` and the command
  -- registry uninitialised; the overview module requires both. The
  -- upstream entry point sets `vim.g.diffview_nvim_loaded` as the last
  -- step of its bootstrap, so a truthy flag is the public readiness
  -- signal.
  if not vim.g.diffview_nvim_loaded then
    notify("diffview-plus.nvim must be installed and loaded first", vim.log.levels.ERROR)
    return
  end
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
  local integration = require("diffview-plus-agents.sidekick")
  integration.cleanup()

  if opts.sidekick then
    -- A single `sidekick` block covers both the status column and the
    -- pairing keymaps; each sub-module reads the keys it cares about and
    -- ignores the rest, so `{ glyph = "*", focus_keymap = "<leader>a" }`
    -- is passed straight through.
    local status = require("diffview-plus-agents.providers.sidekick").setup(opts.sidekick)
    overview.register_status_provider(status)
    M._status_provider = status

    integration.setup(opts.sidekick)
  end
end

return M
