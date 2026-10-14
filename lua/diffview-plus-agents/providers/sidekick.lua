local M = {}

---@class SidekickProviderConfig
---@field glyph string # Prefix rendered before the CLI tool's name (e.g., `●claude`).

---@type SidekickProviderConfig
M.DEFAULTS = {
  glyph = "●",
}

---How long a cached `State.get` result is reused, measured from the
---scan's completion. A worktree overview renders every row in a single
---Lua pass that finishes well under this budget, so N rows share one
---tmux-scan instead of triggering N; the cache then expires in time for
---the next overview open.
local STATE_TTL_MS = 500

---@type table[]?
local _cache_states
---@type integer
local _cache_stamp_ms = 0

---Return sidekick's current session list, served from a short-lived
---cache. `State.get({})` scans tmux panes via `/proc` + `lsof` and is
---expensive per call; without the cache a 20-worktree overview triggered
---20 full scans back-to-back. The stamp is taken AFTER the scan returns,
---not before: on a loaded system a scan can outlast its own TTL window,
---and stamping before would mark the just-populated cache as already
---expired, defeating the cache for every subsequent row.
---@return table[]?
local function get_states()
  local ok, State = pcall(require, "sidekick.cli.state")
  if not ok or type(State) ~= "table" or type(State.get) ~= "function" then
    return nil
  end
  if _cache_states == nil or (vim.uv.now() - _cache_stamp_ms) > STATE_TTL_MS then
    _cache_states = State.get({}) or {}
    _cache_stamp_ms = vim.uv.now()
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
---hands `done` a `<glyph><tool-name>` string for the first session matching
---the entry's path. "Full" means both sidekick-attached sessions and
---external ones sidekick's tmux/zellij backends have discovered via `/proc`
---+ `lsof` process scanning, so an agent you launched directly in a tmux
---pane (without going through sidekick's toggle UI) still lights up the
---status column.
---
---When sidekick is not installed (or the state module cannot be loaded),
---the provider is silently inert (hands `done(nil)`).
---
---`State.get` is still a synchronous shell-out today, so `done` is called
---inline rather than from a libuv worker. Satisfying the overview's new
---`fun(entry, done)` contract keeps the signature right for the day the
---provider grows a true off-main-loop scan.
---@param opts? SidekickProviderConfig|table
---@return fun(entry: GitAdapter.WorktreeEntry, done: fun(result: string?))
function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", M.DEFAULTS, opts or {})

  return function(entry, done)
    if not entry or not entry.path or entry.path == "" then
      done(nil)
      return
    end

    local states = get_states()
    if not states then
      done(nil)
      return
    end

    local target = normalize(entry.path)

    -- Collect every distinct tool whose session matches this worktree.
    -- Many developers run several agents side by side in one project
    -- (e.g., Claude for code, Codex for scaffolding), so collapsing to
    -- the first match hides state the user wants to see. Dedupe by
    -- name so a tool with several panes still renders once. Filter
    -- out dead sessions explicitly: when the user is still focused in
    -- a sidekick float at the moment the agent process exits,
    -- sidekick's own close logic is suppressed (its `atime`-based
    -- debounce treats the exit as "closed too quickly"), so the
    -- terminal lingers in `M.terminals` and keeps showing up in
    -- `State.get`. Each backend implements `is_running`, so trust
    -- that over the stale membership in the state list.
    local parts = {}
    local seen = {}
    for _, s in ipairs(states) do
      if s.session and s.session.cwd == target then
        local tool = s.tool
        if tool and tool.name and not seen[tool.name] then
          local ok, running = pcall(function()
            return s.session:is_running()
          end)
          local alive = not ok or running ~= false
          if alive then
            seen[tool.name] = true
            parts[#parts + 1] = cfg.glyph .. tool.name
          end
        end
      end
    end
    if #parts == 0 then
      done(nil)
    else
      done(table.concat(parts, " "))
    end
  end
end

---Default status function using `M.DEFAULTS`.
M.status = M.setup()

return M
