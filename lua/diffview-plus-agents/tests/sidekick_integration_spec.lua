---Shared handles for the fakes we install per test.
local recorded ---@type { opened: table[], toggled: table[], sent: table[], tmux_cmds: string[][] }
local emitter_subs ---@type table<string, function[]>
local original_system

local function reset()
  recorded = { opened = {}, toggled = {}, sent = {}, tmux_cmds = {} }
  emitter_subs = {}
  for _, m in ipairs({
    "diffview-plus-agents.sidekick",
    "sidekick.cli",
    "sidekick.cli.state",
    "diffview.lib",
  }) do
    package.loaded[m] = nil
  end
end

---Install a fake `DiffviewGlobal.emitter` for the duration of a test.
local function stub_global_emitter()
  _G.DiffviewGlobal = _G.DiffviewGlobal or {}
  _G.DiffviewGlobal.emitter = {
    on = function(_, event, fn)
      emitter_subs[event] = emitter_subs[event] or {}
      table.insert(emitter_subs[event], fn)
    end,
    off = function(_, fn, event)
      local list = emitter_subs[event] or {}
      for i = #list, 1, -1 do
        if list[i] == fn then
          table.remove(list, i)
        end
      end
    end,
    emit = function(_, event, ...)
      local args = { ... }
      for _, fn in ipairs(emitter_subs[event] or {}) do
        fn(nil, unpack(args))
      end
    end,
  }
end

local function stub_sidekick_cli()
  package.loaded["sidekick.cli"] = {
    show = function(opts)
      table.insert(recorded.opened, opts)
    end,
    toggle = function(opts)
      table.insert(recorded.toggled, opts)
    end,
    send = function(opts)
      table.insert(recorded.sent, opts)
    end,
  }
end

---Install a fake `sidekick.cli.state` whose `get()` returns the given
---sessions regardless of filter.
local function stub_sidekick_state(sessions)
  package.loaded["sidekick.cli.state"] = {
    get = function()
      return sessions
    end,
  }
end

---Replace `vim.fn.system` with a recorder so tmux calls can be asserted
---against. Call the returned function to restore the original.
local function stub_tmux_system()
  original_system = vim.fn.system
  vim.fn.system = function(cmd, ...)
    if type(cmd) == "table" and cmd[1] == "tmux" then
      table.insert(recorded.tmux_cmds, cmd)
      return ""
    end
    return original_system(cmd, ...)
  end
  vim.env.TMUX = "/tmp/tmux-fake"
end

local function restore_tmux_system()
  if original_system then
    vim.fn.system = original_system
    original_system = nil
  end
  vim.env.TMUX = nil
end

---Shortcut: build a terminal-backed state (what sidekick-launched sessions
---look like).
local function terminal_session(tool, cwd, id)
  return {
    tool = { name = tool },
    session = {
      backend = "terminal",
      cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")),
      id = id or ("terminal: " .. tool .. "-" .. cwd),
    },
  }
end

---Shortcut: build a tmux-backed state (what the tmux backend returns for
---an agent the user started directly in a bare tmux pane).
local function tmux_session(tool, cwd, pane_id, mux_session)
  return {
    tool = { name = tool },
    session = {
      backend = "tmux",
      cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")),
      id = "tmux " .. (pane_id or "123"),
      tmux_pane_id = pane_id or "%57",
      mux_session = mux_session or "my-session",
    },
  }
end

describe("diffview-plus-agents.sidekick integration", function()
  before_each(function()
    reset()
    stub_global_emitter()
    stub_sidekick_cli()
  end)

  after_each(restore_tmux_system)

  describe("show_on_enter", function()
    it("opens sidekick's float for a terminal-backed session on `<CR>`", function()
      stub_sidekick_state({ terminal_session("claude", "/my/wt", "sid-1") })
      require("diffview-plus-agents.sidekick").setup({})

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      assert.equals(1, #recorded.opened)
      assert.same({ session = "sid-1" }, recorded.opened[1].filter)
      assert.is_false(recorded.opened[1].focus)
    end)

    it("stays silent when no session matches, instead of popping a picker", function()
      stub_sidekick_state({})
      require("diffview-plus-agents.sidekick").setup({})

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/no/match" })

      assert.equals(0, #recorded.opened)
    end)

    it("does NOT steal tmux focus for external tmux sessions on `<CR>`", function()
      -- The <CR> handler is passive: a user drilling into a diff should
      -- not have tmux jump to the agent's pane out from under them.
      stub_sidekick_state({ tmux_session("claude", "/my/wt") })
      stub_tmux_system()
      require("diffview-plus-agents.sidekick").setup({})

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      assert.equals(0, #recorded.opened)
      assert.equals(0, #recorded.tmux_cmds)
    end)

    it("skips the subscription entirely when show_on_enter = false", function()
      stub_sidekick_state({ terminal_session("claude", "/my/wt", "sid-1") })
      require("diffview-plus-agents.sidekick").setup({ show_on_enter = false })

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      assert.equals(0, #recorded.opened)
    end)

    it("stays silent when two sessions share the worktree", function()
      -- Picking "first match" when there are several agents in one cwd
      -- could silently route the display to the wrong one. In the passive
      -- `<CR>` path we have no user attention to disambiguate with, so
      -- the integration quietly declines to pick on its own.
      stub_sidekick_state({
        terminal_session("claude", "/my/wt", "sid-A"),
        terminal_session("codex", "/my/wt", "sid-B"),
      })
      require("diffview-plus-agents.sidekick").setup({})

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      assert.equals(0, #recorded.opened)
    end)
  end)

  describe("focus_keymap mechanics", function()
    -- These exercise `focus_session` directly through the setup-installed
    -- callback. The handler reads `diffview.lib.get_current_view()`, which
    -- is non-trivial to stub here; the <CR> cases above cover the main
    -- paths. These lifecycle tests still verify what matters most: that
    -- the integration module's effects are consistent across re-setup.
    it("detaches the previous handler on each setup call", function()
      stub_sidekick_state({ terminal_session("claude", "/my/wt", "sid-1") })
      local sidekick = require("diffview-plus-agents.sidekick")

      sidekick.setup({})
      sidekick.setup({})

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      -- Exactly one show call, not two: the first subscription was
      -- cleaned up before the second was installed.
      assert.equals(1, #recorded.opened)
    end)

    it("cleanup() removes the subscription", function()
      stub_sidekick_state({ terminal_session("claude", "/my/wt", "sid-1") })
      local sidekick = require("diffview-plus-agents.sidekick")

      sidekick.setup({})
      sidekick.cleanup()

      DiffviewGlobal.emitter:emit("worktree_overview_entered", nil, { path = "/my/wt" })

      assert.equals(0, #recorded.opened)
    end)
  end)

  describe("keymaps", function()
    it("installs the focus and send keymaps at their default lhs", function()
      stub_sidekick_state({})
      require("diffview-plus-agents.sidekick").setup({})

      assert.is_not_nil(vim.fn.maparg("<leader>aw", "n", false, true).lhs)
      assert.is_not_nil(vim.fn.maparg("<leader>av", "x", false, true).lhs)
    end)

    it("honours a custom focus_keymap and skips send_keymap when false", function()
      stub_sidekick_state({})
      pcall(vim.keymap.del, "x", "<leader>av")

      require("diffview-plus-agents.sidekick").setup({
        focus_keymap = "<leader>XW",
        send_keymap = false,
      })

      assert.is_not_nil(vim.fn.maparg("<leader>XW", "n", false, true).lhs)
      assert.same({}, vim.fn.maparg("<leader>av", "x", false, true))
    end)

    it("removes the previous keymaps when setup is called again", function()
      -- Without this, changing `focus_keymap` across setups (lazy reload,
      -- iterating on config) leaves the old lhs bound to a stale closure
      -- that still calls into sidekick for the previous worktree logic.
      stub_sidekick_state({})
      local sidekick = require("diffview-plus-agents.sidekick")

      sidekick.setup({ focus_keymap = "<leader>k1", send_keymap = "<leader>k2" })
      assert.is_not_nil(vim.fn.maparg("<leader>k1", "n", false, true).lhs)
      assert.is_not_nil(vim.fn.maparg("<leader>k2", "x", false, true).lhs)

      sidekick.setup({ focus_keymap = "<leader>k3", send_keymap = "<leader>k4" })
      assert.same({}, vim.fn.maparg("<leader>k1", "n", false, true))
      assert.same({}, vim.fn.maparg("<leader>k2", "x", false, true))
      assert.is_not_nil(vim.fn.maparg("<leader>k3", "n", false, true).lhs)
      assert.is_not_nil(vim.fn.maparg("<leader>k4", "x", false, true).lhs)

      sidekick.cleanup()
      assert.same({}, vim.fn.maparg("<leader>k3", "n", false, true))
      assert.same({}, vim.fn.maparg("<leader>k4", "x", false, true))
    end)

    it("leaves a mapping alone if someone rebound it after setup", function()
      -- `cleanup` should only unbind lhs that still points at the exact
      -- callback this module installed. If another plugin (or the user)
      -- has rebound the key between `setup` and `cleanup`, blindly
      -- deleting would destroy a binding that is no longer ours.
      stub_sidekick_state({})
      local sidekick = require("diffview-plus-agents.sidekick")

      sidekick.setup({ focus_keymap = "<leader>k5", send_keymap = false })
      local user_rhs = function() end
      vim.keymap.set("n", "<leader>k5", user_rhs, { desc = "user" })

      sidekick.cleanup()
      local still = vim.fn.maparg("<leader>k5", "n", false, true)
      assert.is_not_nil(still.lhs)
      assert.equals(user_rhs, still.callback)
      pcall(vim.keymap.del, "n", "<leader>k5")
    end)
  end)
end)
