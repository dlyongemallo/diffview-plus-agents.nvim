local M = {}

---@class SidekickProviderConfig
---@field glyph string # Prefix rendered before the CLI tool's name (e.g., `●claude`).

---@type SidekickProviderConfig
M.DEFAULTS = {
  glyph = "●",
}

---How long a cached `State.get` result is reused. A worktree overview
---renders every row in a single Lua pass that finishes well under this
---budget, so N rows share one tmux-scan instead of triggering N; the
---cache then expires in time for the next overview open.
local STATE_TTL_MS = 500

---@type table[]?
local _cache_states
---@type integer
local _cache_stamp_ms = 0

---Return sidekick's current session list, served from a short-lived
---cache. `State.get({})` scans tmux panes via `/proc` + `lsof` and is
---expensive per call; without the cache a 20-worktree overview triggered
---20 full scans back-to-back.
---@return table[]?
local function get_states()
  local ok, State = pcall(require, "sidekick.cli.state")
  if not ok or type(State) ~= "table" or type(State.get) ~= "function" then
    return nil
  end
  local now = vim.uv.now()
  if _cache_states == nil or (now - _cache_stamp_ms) > STATE_TTL_MS then
    _cache_states = State.get({}) or {}
    _cache_stamp_ms = now
  end
  return _cache_states
end

---Drop the cached session list. Tests use this to isolate cases that
---stub a new `State.get` behaviour between invocations.
function M._invalidate_cache()
  _cache_states = nil
  _cache_stamp_ms = 0
end

---Normalise a path the same way `sidekick.cli.Session` does, so the equality
---check against `session.cwd` doesn't miss on trailing-slash or symlink
---shape differences.
---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---Build a status function that queries sidekick's full session list and
---returns `<glyph><tool-name>` for the first session matching the entry's
---path. "Full" means both sidekick-attached sessions and external ones
---sidekick's tmux/zellij backends have discovered via `/proc` + `lsof`
---process scanning, so an agent you launched directly in a tmux pane
---(without going through sidekick's toggle UI) still lights up the status
---column.
---
---When sidekick is not installed (or the state module cannot be loaded),
---the provider is silently inert.
---@param opts? SidekickProviderConfig|table
---@return fun(entry: GitAdapter.WorktreeEntry): string?
function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", M.DEFAULTS, opts or {})

  return function(entry)
    if not entry or not entry.path or entry.path == "" then
      return nil
    end

    local states = get_states()
    if not states then
      return nil
    end

    local target = normalize(entry.path)

    for _, s in ipairs(states) do
      if s.session and s.session.cwd == target then
        local tool = s.tool
        if tool and tool.name then
          return cfg.glyph .. tool.name
        end
      end
    end

    return nil
  end
end

---Default status function using `M.DEFAULTS`.
M.status = M.setup()

return M
