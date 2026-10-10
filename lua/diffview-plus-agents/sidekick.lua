local M = {}

local NOTIFY_TITLE = "diffview+agents"

local function notify(msg, level)
  vim.notify(msg, level, { title = NOTIFY_TITLE })
end

---@class DiffviewPlusAgents.Sidekick.Config
---@field show_on_enter boolean # Auto-show the agent's pane (sidekick float or tmux window) for the chosen worktree on `<CR>` in the overview.
---@field focus_keymap string|false # Normal-mode key that focuses the agent attached to the worktree the user is on (overview row or DiffView tab). For sidekick-launched sessions this shows the float; for sessions discovered in bare tmux panes it `tmux select-window`s to the agent's pane. Set to `false` to skip the mapping.
---@field send_keymap string|false # Visual-mode key that sends the current selection to the agent attached to the DiffView's worktree. Set to `false` to skip the mapping.

---@type DiffviewPlusAgents.Sidekick.Config
M.DEFAULTS = {
  show_on_enter = true,
  focus_keymap = "<leader>aw",
  send_keymap = "<leader>av",
}

---Return every sidekick session whose `cwd` matches `path`. Callers can
---decide what to do with 0, 1, or >1 matches (passive flows use the first
---match; active flows disambiguate via `vim.ui.select`). Sidekick's own
---`filter.cwd` is a boolean matching nvim's current cwd, not an arbitrary
---path, so routing by worktree path is done client-side.
---@param path string?
---@return table[]
local function states_for(path)
  if not path or path == "" then
    return {}
  end
  local target = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local ok, State = pcall(require, "sidekick.cli.state")
  if not ok then
    return {}
  end
  local matches = {}
  for _, s in ipairs(State.get({}) or {}) do
    if s.session and s.session.cwd == target then
      matches[#matches + 1] = s
    end
  end
  return matches
end

---Short label for a session as it appears in the ambiguity picker.
---@param state table
---@return string
local function describe_session(state)
  local tool = state.tool and state.tool.name or "?"
  local backend = state.session and state.session.backend or "?"
  return tool .. " (" .. backend .. ")"
end

---Resolve a single session for an active flow, prompting the user when
---more than one agent is attached to the same worktree. Calls `cb(state)`
---with the chosen state, or `cb(nil)` and a notification when nothing
---matches. For passive flows (background render-time hooks) call
---`states_for` directly instead; the picker is only sensible for
---user-initiated actions, and `send_keymap` in particular wants it so
---code never silently leaves for the wrong agent.
---@param path string?
---@param action string # Verb for the picker prompt ("focus", "send to").
---@param cb fun(state: table?)
local function pick_session(path, action, cb)
  local matches = states_for(path)
  if #matches == 0 then
    notify(("no attached session for %s"):format(path or "?"), vim.log.levels.INFO)
    cb(nil)
    return
  end
  if #matches == 1 then
    cb(matches[1])
    return
  end
  vim.ui.select(matches, {
    prompt = ("Which agent to %s?"):format(action),
    format_item = describe_session,
  }, function(chosen)
    cb(chosen)
  end)
end

---Resolve the worktree path the user is "pointing at" right now.
---On the overview buffer that is the entry under the cursor; in a DiffView
---tab it is the adapter's toplevel.
---@return string?
local function current_worktree_path()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if not view then
    return nil
  end
  if view._visible_entries and view.winid and vim.api.nvim_win_is_valid(view.winid) then
    local lnum = vim.api.nvim_win_get_cursor(view.winid)[1]
    local entry = view._visible_entries[lnum]
    if entry then
      return entry.path
    end
  end
  return view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
end

---Resolve the worktree path owning the current DiffView tab, if any.
---Overview rows are deliberately not consulted here: the "send hunk back"
---flow is only sensible from within a DiffView.
---@return string?
local function current_diffview_path()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  return view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
end

---Bring the agent's pane into view. For sidekick-launched sessions
---(`backend = "terminal"`) that means showing the sidekick float. For
---externally-adopted tmux sessions (`backend = "tmux"`) there is no float
---to show, so we `tmux select-window` to the pane running the agent. Any
---other backend returns nil (caller may `vim.notify` or ignore).
---
---`active` controls disruption: in passive contexts (the `<CR>`
---auto-open, where the user is heading into a DiffView and should stay
---there), the float is shown but the cursor stays put, and tmux focus is
---left alone. In active contexts (the focus keymap, where the user
---explicitly asked to go to the agent), the cursor moves into the float
---for a terminal backend and tmux is switched for a tmux backend.
---@param state table
---@param active boolean
---@return "float"|"tmux"|nil
local function focus_session(state, active)
  local session = state and state.session
  if not session then
    return nil
  end
  if session.backend == "terminal" then
    require("sidekick.cli").show({
      filter = { session = session.id },
      focus = active,
    })
    return "float"
  end
  if not active then
    return nil
  end
  if session.backend == "tmux" and session.tmux_pane_id and vim.env.TMUX then
    -- `switch-client -t <session>` handles the cross-tmux-session case;
    -- `select-window -t <pane_id>` picks the window containing the pane,
    -- but on its own it leaves pane focus unchanged, so when Neovim and
    -- the agent live in different panes of the same window the user
    -- would stay in nvim. `select-pane -t <pane_id>` resolves that.
    -- When any of these are already current, each is a no-op.
    if session.mux_session then
      vim.fn.system({ "tmux", "switch-client", "-t", session.mux_session })
    end
    vim.fn.system({ "tmux", "select-window", "-t", session.tmux_pane_id })
    vim.fn.system({ "tmux", "select-pane", "-t", session.tmux_pane_id })
    return "tmux"
  end
  return nil
end

---Current emitter subscription so repeat setups can detach the previous one
---before attaching anew. Lazy reloads and iterating on the config no longer
---stack handlers.
---@type (fun(_, view, entry: GitAdapter.WorktreeEntry))?
local _on_entered

---Autocmd group backing the sidekick-event hooks (`SidekickCliAttach` /
---`SidekickCliDetach`) and the overview `FocusGained` trigger. Keyed by
---name so `cleanup` can clear it wholesale without tracking individual
---autocmd ids.
local _au_group = "diffview-plus-agents.sidekick"

---Mappings this module installed, each as `{ mode, lhs, callback }`.
---`callback` is the exact function we handed to `vim.keymap.set`; we
---compare the live mapping against it on cleanup so we only ever remove
---bindings this module still owns. Without this, deleting by `lhs`
---alone would destroy a mapping the user bound to the same key after
---the integration was set up.
---@type { [1]: string, [2]: string, [3]: function }[]
local _mappings = {}

---Detach the emitter subscription and remove the keymaps this module
---still owns. A mapping whose callback was replaced by another plugin
---or by the user after `setup` is left alone.
function M.cleanup()
  if _on_entered then
    DiffviewGlobal.emitter:off(_on_entered, "worktree_overview_entered")
    _on_entered = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, _au_group)
  for _, m in ipairs(_mappings) do
    local mode, lhs, callback = m[1], m[2], m[3]
    local current = vim.fn.maparg(lhs, mode, false, true)
    if current.callback == callback then
      pcall(vim.keymap.del, mode, lhs)
    end
  end
  _mappings = {}
end

---Install a keymap and remember both its coordinates and callback so
---`cleanup` can tell whether we still own the live binding.
local function install_keymap(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, opts)
  _mappings[#_mappings + 1] = { mode, lhs, rhs }
end

---Wire the overview-entered event and the paired keymaps.
---Idempotent: calling it again replaces the previous registration.
---@param opts? DiffviewPlusAgents.Sidekick.Config|table
function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", M.DEFAULTS, opts or {})
  M.cleanup()

  if cfg.show_on_enter then
    _on_entered = function(_, _, entry)
      -- Passive: open sidekick's float if there is one, but do not steal
      -- tmux focus; the user is heading into the DiffView and should stay
      -- there. On ambiguity (several sessions in the same worktree) keep
      -- quiet rather than popping a picker mid-navigation; the focus
      -- keymap below is the user-initiated path that disambiguates.
      local matches = states_for(entry.path)
      if #matches == 1 then
        focus_session(matches[1], false)
      end
    end
    DiffviewGlobal.emitter:on("worktree_overview_entered", _on_entered)
  end

  -- Ask the overview to re-score the status column whenever sidekick
  -- gains or loses a session. The emitted event triggers the view's
  -- `refresh_status` (status providers only, no git), so a user hitting
  -- `<leader>aa` to attach a tool sees the row light up without having
  -- to press `R`. The cache invalidation forces the first provider call
  -- to do a fresh `State.get` scan; otherwise it would read the stale
  -- cached list that predates the attach/detach.
  local function request_status_refresh()
    require("diffview-plus-agents.providers.sidekick")._invalidate_cache()
    pcall(function()
      DiffviewGlobal.emitter:emit("refresh_worktree_overview_status")
    end)
  end
  local group = vim.api.nvim_create_augroup(_au_group, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "SidekickCliAttach", "SidekickCliDetach" },
    callback = request_status_refresh,
  })
  -- Also catch externally-discovered sessions (agents started directly in
  -- a bare tmux pane): sidekick does not emit `SidekickCli*` for those,
  -- so refresh whenever the user returns to the overview. `FocusGained`
  -- covers "switched away from nvim and back" (requires tmux `set -g
  -- focus-events on`), and `BufEnter` covers "switched tabs/windows
  -- inside nvim" (works regardless of terminal/tmux cooperation).
  -- The filetype guard means this never fires on unrelated buffers.
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = function()
      if vim.bo.filetype == "DiffviewWorktreeOverview" then
        request_status_refresh()
      end
    end,
  })

  if cfg.focus_keymap then
    install_keymap("n", cfg.focus_keymap, function()
      local cwd = current_worktree_path()
      if not cwd then
        notify("not in a diffview-plus view", vim.log.levels.INFO)
        return
      end
      pick_session(cwd, "focus", function(state)
        if not state then
          return
        end
        local result = focus_session(state, true)
        if not result then
          local backend = state.session and state.session.backend or "?"
          notify(("cannot focus session (backend=%s)"):format(backend), vim.log.levels.INFO)
        end
      end)
    end, { desc = "Focus this worktree's agent" })
  end

  if cfg.send_keymap then
    install_keymap("x", cfg.send_keymap, function()
      -- Visual-mode Lua callbacks run while still in visual mode, so the
      -- `'<`/`'>` marks that `sidekick.cli.send`'s `{selection}` template
      -- reads still point at the PREVIOUS selection. Feed `<Esc>` first
      -- so the marks flush to the current one before we send.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      local cwd = current_diffview_path()
      pick_session(cwd, "send selection to", function(state)
        if not state or not state.session then
          return
        end
        require("sidekick.cli").send({
          msg = "{selection}",
          filter = { session = state.session.id },
        })
      end)
    end, { desc = "Send hunk to this worktree's agent" })
  end
end

return M
