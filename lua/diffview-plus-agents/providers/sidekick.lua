local M = {}

---@class SidekickProviderConfig
---@field glyph? string # Prefix rendered before the CLI tool's name (e.g., `●claude`).
---@field glyph_hl? string|false # Highlight group for the glyph. Defaults to `DiffviewNonText`, matching the overview's own chrome punctuation so the glyph recedes visually alongside the model/effort label; set to `false` to render the glyph with the status column's default highlight instead.
---@field show_model? boolean|table # Append `:<model>` after the tool name. `true` is shorthand for `{ enabled = true, live = false }`; the subtable adds `live = true` to also scrape the tmux pane for a model the user may have switched to mid-session.
---@field show_effort? boolean # Append `:<effort>` after the model (when both are known). Ignored when `show_model` is off or the resolver cannot determine a model.

---@type SidekickProviderConfig
M.DEFAULTS = {
  glyph = "●",
  glyph_hl = "DiffviewNonText",
  show_model = false,
  show_effort = false,
}

---Normalize the `show_model` config into a `{ enabled, live }` table. Users
---may pass `false`/nil to disable, `true` as shorthand for enabled + launch-
---time only, or the explicit subtable. Keeping the shape uniform means the
---hot path at render time is a pair of field reads rather than a type check.
---@param v boolean|table|nil
---@return { enabled: boolean, live: boolean }
local function normalize_show_model(v)
  if v == true then
    return { enabled = true, live = false }
  end
  if type(v) == "table" then
    return { enabled = v.enabled == true, live = v.live == true }
  end
  return { enabled = false, live = false }
end

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
---stub a new `State.get` behaviour between invocations. Also purges the
---model resolver's per-session cache so stale `(model, effort)` entries
---never outlive the session they were resolved from.
function M._invalidate_cache()
  _cache_states = nil
  _cache_stamp_ms = 0
  local ok, model = pcall(require, "diffview-plus-agents.providers.model")
  if ok and type(model._invalidate_cache) == "function" then
    model._invalidate_cache()
  end
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
  local show_model = normalize_show_model(cfg.show_model)
  local resolver_opts = { live = show_model.live }
  -- `glyph_hl = false` is the escape hatch for users who want the glyph
  -- to pick up the status column's default highlight alongside the label;
  -- `or nil` collapses both `false` and `nil` so the segment omits the key.
  local glyph_hl = cfg.glyph_hl or nil

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
    -- Build the row as `{ glyph, label }` pairs per matching session,
    -- plus a `" "` separator between sessions. On older diffview-plus
    -- the segments are flattened into a plain string before dispatch.
    local segments = {}
    local seen = {}
    for _, s in ipairs(states) do
      local tool = s.tool
      if
        not s.session
        or s.session.cwd ~= target
        or not tool
        or not tool.name
        or seen[tool.name]
      then
        goto continue
      end
      local ok, running = pcall(function()
        return s.session:is_running()
      end)
      if ok and running == false then
        goto continue
      end
      seen[tool.name] = true
      -- Sidekick names the tool `antigravity` (matching its upstream module
      -- path), but the binary is `agy` and the status column has very
      -- little room; render the shorter form so it does not dominate the
      -- row. Other tool names already read as the CLI name.
      local label = tool.name == "antigravity" and "agy" or tool.name
      if show_model.enabled then
        local info =
          require("diffview-plus-agents.providers.model").resolve(s.session, resolver_opts)
        if info.model then
          label = label .. ":" .. info.model
          if cfg.show_effort and info.effort then
            label = label .. ":" .. info.effort
          end
        end
      end
      if #segments > 0 then
        segments[#segments + 1] = { text = " " }
      end
      segments[#segments + 1] = { text = cfg.glyph, hl = glyph_hl }
      segments[#segments + 1] = { text = label }
      ::continue::
    end
    if #segments == 0 then
      done(nil)
    else
      done(segments)
    end
  end
end

---Default status function using `M.DEFAULTS`.
M.status = M.setup()

return M
