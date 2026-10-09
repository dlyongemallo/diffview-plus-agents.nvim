local M = {}

---@class CodingAgentProviderSpec
---@field name? string # Short label; when set and `status` is absent, loads the matching built-in via `providers/<name>.setup(opts)`.
---@field opts? table # Options passed to the built-in's `setup(opts)` factory.
---@field status? fun(entry: GitAdapter.WorktreeEntry): string? # Explicit status fn; wins over `name` when both are set.

---@alias CodingAgentProviderDef
---| string                     # Name of a built-in provider under `providers/`.
---| CodingAgentProviderSpec    # Inline table (`{name, opts?}` or `{status}`).
---| fun(entry: GitAdapter.WorktreeEntry): string? # Bare status function.

---@class DiffviewPlusCodingAgentsConfig
---@field providers CodingAgentProviderDef[]
---@field sidekick? DiffviewPlusCodingAgents.Sidekick.Config|table # Opt-in sidekick.nvim integration. Pass `{}` to enable with defaults; omit to disable.

---Status functions registered on the diffview+ overview, in registration order.
---Kept so a second `setup()` call unregisters the previous batch before
---installing the new one; otherwise reloading the plugin would stack providers.
---@type (fun(entry: GitAdapter.WorktreeEntry): string?)[]
M._registered = {}

---Load a built-in provider module by name.
---@param name string
---@return table? module
local function load_builtin(name)
  local ok, mod = pcall(require, "diffview-plus-coding-agents.providers." .. name)
  if not ok or type(mod) ~= "table" then
    vim.notify(
      ("diffview-plus-coding-agents: unknown provider '%s'"):format(name),
      vim.log.levels.WARN
    )
    return nil
  end
  return mod
end

---Resolve a provider definition to its status function.
---
---- A bare function is used as-is.
---- A string names a built-in: `providers.<name>.status` (no opts).
---- An inline table may carry either `status` (used directly) or `name`
---  plus optional `opts`. In the latter case the built-in's `setup(opts)`
---  factory is called to produce a configured status function; absent a
---  `setup`, the module's `.status` is used as a fallback.
---
---Returns nil (and warns) when the shape is unrecognised, so one bad
---entry does not take the whole setup down.
---@param def CodingAgentProviderDef
---@return (fun(entry: GitAdapter.WorktreeEntry): string?)?
local function resolve_provider(def)
  if type(def) == "function" then
    return def
  end
  if type(def) == "string" then
    local mod = load_builtin(def)
    if not mod or type(mod.status) ~= "function" then
      vim.notify(
        ("diffview-plus-coding-agents: provider '%s' has no `status` function"):format(def),
        vim.log.levels.WARN
      )
      return nil
    end
    return mod.status
  end
  if type(def) == "table" then
    if type(def.status) == "function" then
      return def.status
    end
    if type(def.name) == "string" then
      local mod = load_builtin(def.name)
      if not mod then
        return nil
      end
      if type(mod.setup) == "function" then
        return mod.setup(def.opts)
      end
      if type(mod.status) == "function" then
        return mod.status
      end
      vim.notify(
        ("diffview-plus-coding-agents: provider '%s' exposes neither `setup` nor `status`"):format(
          def.name
        ),
        vim.log.levels.WARN
      )
      return nil
    end
  end
  vim.notify(
    "diffview-plus-coding-agents: provider entry must be a string, function, "
      .. "or table with `name` or `status`",
    vim.log.levels.WARN
  )
  return nil
end

---Register the configured providers with diffview+'s worktree-overview status
---column. Idempotent: calling it again replaces the previous registration.
---@param opts? DiffviewPlusCodingAgentsConfig
function M.setup(opts)
  opts = opts or {}

  local ok, overview =
    pcall(require, "diffview.scene.views.worktree_overview.worktree_overview_view")
  if not ok then
    vim.notify(
      "diffview-plus-coding-agents: diffview-plus.nvim must be installed and loaded first",
      vim.log.levels.ERROR
    )
    return
  end

  for _, fn in ipairs(M._registered) do
    overview.unregister_status_provider(fn)
  end
  M._registered = {}

  for _, def in ipairs(opts.providers or {}) do
    local fn = resolve_provider(def)
    if fn then
      overview.register_status_provider(fn)
      table.insert(M._registered, fn)
    end
  end

  -- Opt-in sidekick.nvim integration (event subscription + pairing keymaps).
  -- A `sidekick` block in the config (even an empty table) enables it;
  -- omitting the key leaves the integration cleaned up so a disabled-via-
  -- reload setup properly tears down any previously installed handlers.
  local sidekick = require("diffview-plus-coding-agents.sidekick")
  if opts.sidekick then
    sidekick.setup(opts.sidekick)
  else
    sidekick.cleanup()
  end
end

return M
