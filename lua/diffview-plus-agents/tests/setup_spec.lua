---Reset `package.loaded` so each test re-evaluates the plugin and its
---sub-modules from source. The integration module in particular caches
---mapping state across its own `cleanup`/`setup` cycle, so keeping the
---plugin loaded between tests would carry residue over.
local function reset_modules()
  for _, m in ipairs({
    "diffview-plus-agents",
    "diffview-plus-agents.sidekick",
    "diffview-plus-agents.providers.sidekick",
  }) do
    package.loaded[m] = nil
  end
end

---Invoke a `fun(entry, done)` provider and return the string it hands to
---`done`. The sidekick provider still settles `done` inside its own body,
---so this one-shot call-and-collect wrapper matches the real view's
---semantics while keeping the test-side ergonomics identical to the old
---synchronous return.
---@param fn fun(entry: table?, done: fun(result: string?))
---@param entry table?
---@return string?
local function sync_call(fn, entry)
  local result
  local called = false
  fn(entry, function(r)
    result = r
    called = true
  end)
  assert.is_true(called)
  return result
end

---Install a fake worktree-overview module in `package.loaded`. Returns the
---`registered` list so tests can assert what the plugin registered on it.
---@return (fun(entry: table, done: fun(result: string?)))[] registered
local function stub_overview()
  local registered = {}
  local overview = {
    register_status_provider = function(fn)
      table.insert(registered, fn)
    end,
    unregister_status_provider = function(fn)
      for i = #registered, 1, -1 do
        if registered[i] == fn then
          table.remove(registered, i)
        end
      end
    end,
  }
  package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = overview
  return registered
end

---Make `DiffviewGlobal.emitter` a stub so the integration module can
---`on`/`off` without reaching real diffview. Returns `subs` (so tests
---can assert what was subscribed to) and `emits` (a flat list of every
---event name the module tried to emit, in order).
local function stub_emitter()
  local subs = {}
  local emits = {}
  _G.DiffviewGlobal = _G.DiffviewGlobal or {}
  _G.DiffviewGlobal.emitter = {
    on = function(_, event, fn)
      subs[event] = subs[event] or {}
      table.insert(subs[event], fn)
    end,
    off = function(_, fn, event)
      local list = subs[event] or {}
      for i = #list, 1, -1 do
        if list[i] == fn then
          table.remove(list, i)
        end
      end
    end,
    emit = function(_, event)
      emits[#emits + 1] = event
    end,
  }
  return subs, emits
end

local function unstub()
  package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = nil
end

describe("diffview-plus-agents setup", function()
  local original_loaded_flag
  before_each(function()
    reset_modules()
    -- Simulate diffview-plus having completed its own `plugin/diffview.lua`
    -- bootstrap. The two "not loaded" tests below clear this inside their
    -- bodies to exercise the error path.
    original_loaded_flag = vim.g.diffview_nvim_loaded
    vim.g.diffview_nvim_loaded = 1
  end)
  after_each(function()
    unstub()
    vim.g.diffview_nvim_loaded = original_loaded_flag
  end)

  it("errors (does not crash) when diffview-plus is not loaded", function()
    -- Not stubbing the overview module simulates diffview+ being absent.
    -- Clear the readiness flag the fixture set so the guard trips.
    vim.g.diffview_nvim_loaded = nil
    local notified
    local original = vim.notify
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end
    require("diffview-plus-agents").setup({ sidekick = {} })
    vim.notify = original

    assert.is_not_nil(notified)
    assert.equals(vim.log.levels.ERROR, notified.level)
    -- Plugin name goes in the `title` (shown by notify UIs like
    -- `rcarriga/nvim-notify`); the message is the actual error.
    assert.equals("diffview+agents", notified.opts and notified.opts.title)
    assert.is_truthy(notified.msg:find("diffview-plus.nvim", 1, true))
  end)

  it("errors when the overview module is reachable but diffview-plus is not loaded", function()
    -- Regression: a lazy-loaded diffview-plus whose `plugin/diffview.lua`
    -- has not been sourced yet still has its modules on `runtimepath`, so
    -- `pcall(require, ...)` succeeds. Without the `vim.g` guard, `setup`
    -- would then run against uninitialised diffview state. Stub the
    -- overview module AND clear the flag to simulate that race.
    stub_overview()
    stub_emitter()
    vim.g.diffview_nvim_loaded = nil
    local notified
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end
    require("diffview-plus-agents").setup({ sidekick = {} })
    vim.notify = original_notify

    assert.is_not_nil(notified)
    assert.equals(vim.log.levels.ERROR, notified.level)
    assert.is_truthy(notified.msg:find("diffview-plus.nvim", 1, true))
  end)

  it("registers nothing when `sidekick` is omitted", function()
    local registered = stub_overview()
    stub_emitter()
    require("diffview-plus-agents").setup({})
    require("diffview-plus-agents").setup()
    assert.equals(0, #registered)
  end)

  it("registers a sidekick status provider when `sidekick = {}` is set", function()
    local registered = stub_overview()
    stub_emitter()
    require("diffview-plus-agents").setup({ sidekick = {} })
    assert.equals(1, #registered)
    assert.equals("function", type(registered[1]))
  end)

  it("passes `sidekick` options through to the status provider's factory", function()
    local registered = stub_overview()
    stub_emitter()
    package.loaded["sidekick.cli.state"] = {
      get = function()
        return {
          { tool = { name = "claude" }, session = { cwd = vim.fs.normalize("/w") } },
        }
      end,
    }

    require("diffview-plus-agents").setup({ sidekick = { glyph = "*" } })
    assert.equals("*claude", sync_call(registered[1], { path = "/w" }))

    package.loaded["sidekick.cli.state"] = nil
  end)

  it("wires the integration module when `sidekick` is set", function()
    stub_overview()
    local subs = stub_emitter()
    require("diffview-plus-agents").setup({ sidekick = {} })
    -- `show_on_enter` defaults to true, so the module subscribes.
    assert.equals(1, #(subs["worktree_overview_entered"] or {}))
  end)

  it("replaces the previous registration on each call", function()
    local registered = stub_overview()
    stub_emitter()

    require("diffview-plus-agents").setup({ sidekick = {} })
    local first = registered[1]
    require("diffview-plus-agents").setup({ sidekick = {} })

    assert.equals(1, #registered)
    assert.is_not.equals(first, registered[1])
  end)

  it("tears down previous registration when `sidekick` is dropped on reload", function()
    local registered = stub_overview()
    stub_emitter()

    require("diffview-plus-agents").setup({ sidekick = {} })
    assert.equals(1, #registered)

    require("diffview-plus-agents").setup({})
    assert.equals(0, #registered)
  end)

  it("emits `refresh_worktree_overview_status` on `SidekickCliAttach`", function()
    stub_overview()
    local _, emits = stub_emitter()
    local invalidated = false
    package.loaded["diffview-plus-agents.providers.sidekick"] = {
      setup = function()
        return function(_, done)
          done(nil)
        end
      end,
      _invalidate_cache = function()
        invalidated = true
      end,
    }

    require("diffview-plus-agents").setup({ sidekick = {} })

    -- The autocmd lives on the real `vim.api`; fire the event the way
    -- sidekick does and assert the integration reacted.
    vim.api.nvim_exec_autocmds("User", { pattern = "SidekickCliAttach" })

    assert.is_true(invalidated)
    local saw
    for _, e in ipairs(emits) do
      if e == "refresh_worktree_overview_status" then
        saw = true
        break
      end
    end
    assert.is_true(saw)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  it("tears down the SidekickCli autocmd when `sidekick` is dropped on reload", function()
    stub_overview()
    local _, emits = stub_emitter()
    package.loaded["diffview-plus-agents.providers.sidekick"] = {
      setup = function()
        return function(_, done)
          done(nil)
        end
      end,
      _invalidate_cache = function() end,
    }

    require("diffview-plus-agents").setup({ sidekick = {} })
    require("diffview-plus-agents").setup({})

    local before = #emits
    vim.api.nvim_exec_autocmds("User", { pattern = "SidekickCliDetach" })
    assert.equals(before, #emits)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  ---Install a provider stub that counts cache invalidations. Reused by
  ---the "soft vs hard" tests below so each can assert on the counter.
  local function stub_provider()
    local state = { invalidations = 0 }
    package.loaded["diffview-plus-agents.providers.sidekick"] = {
      setup = function()
        return function(_, done)
          done(nil)
        end
      end,
      _invalidate_cache = function()
        state.invalidations = state.invalidations + 1
      end,
    }
    return state
  end

  ---Make the current buffer appear as a worktree overview so the
  ---filetype-guarded autocmds will fire. Returns the buffer so tests
  ---can clean up or reference it later.
  local function make_overview_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "DiffviewWorktreeOverview"
    return buf
  end

  it("soft-refreshes on `BufEnter` without invalidating the provider cache", function()
    stub_overview()
    local _, emits = stub_emitter()
    local provider = stub_provider()

    require("diffview-plus-agents").setup({ sidekick = {} })
    local before = #emits
    make_overview_buffer()
    vim.api.nvim_exec_autocmds("BufEnter", {})

    assert.is_true(#emits > before)
    assert.equals(0, provider.invalidations)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  it("ignores `BufEnter` on unrelated buffers", function()
    stub_overview()
    local _, emits = stub_emitter()
    stub_provider()

    require("diffview-plus-agents").setup({ sidekick = {} })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "lua"

    local before = #emits
    vim.api.nvim_exec_autocmds("BufEnter", {})
    assert.equals(before, #emits)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  it("soft-refreshes on `WinEnter` and `FocusGained` on the overview", function()
    stub_overview()
    local _, emits = stub_emitter()
    local provider = stub_provider()

    require("diffview-plus-agents").setup({ sidekick = {} })
    make_overview_buffer()

    local before = #emits
    vim.api.nvim_exec_autocmds("WinEnter", {})
    assert.is_true(#emits > before)
    before = #emits
    vim.api.nvim_exec_autocmds("FocusGained", {})
    assert.is_true(#emits > before)

    -- Neither soft trigger invalidates the TTL cache; the provider's
    -- own 500ms window coalesces repeat events.
    assert.equals(0, provider.invalidations)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  it("debounces `CursorMoved` into a single trailing soft refresh", function()
    stub_overview()
    local _, emits = stub_emitter()
    local provider = stub_provider()

    require("diffview-plus-agents").setup({ sidekick = {} })
    make_overview_buffer()

    local before = #emits
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("CursorMoved", {})
    end
    -- Immediately after the burst, nothing has fired yet.
    assert.equals(before, #emits)
    -- After the debounce window plus a small slack, exactly one soft
    -- refresh has arrived for the whole burst.
    vim.wait(500, function()
      return #emits > before
    end)
    assert.equals(before + 1, #emits)
    assert.equals(0, provider.invalidations)

    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  end)

  it("pins the overview tab's cwd to the worktree under the cursor", function()
    -- Why this exists: sidekick's `Session.new` reads `vim.fn.getcwd(0)`
    -- at attach time with no plumbing for the caller to override it, so
    -- `<leader>as` on the overview launches the new agent in whichever
    -- cwd the overview tab happens to carry. Pinning the tab's cwd to
    -- the row under the cursor on every move keeps those launches
    -- attached to the right worktree.
    stub_overview()
    stub_emitter()
    stub_provider()

    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local original_cwd = vim.fn.getcwd()
    local win = vim.api.nvim_get_current_win()

    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return {
          _visible_entries = { { path = tmp } },
          winid = win,
          adapter = { ctx = { toplevel = tmp } },
        }
      end,
    }

    local ok, err = pcall(function()
      require("diffview-plus-agents").setup({ sidekick = {} })
      make_overview_buffer()
      -- The autocmd group fires `_sync_tab_cwd` on CursorMoved; drive
      -- it directly rather than racing a real cursor move.
      require("diffview-plus-agents.sidekick")._sync_tab_cwd()

      assert.equals(vim.fs.normalize(tmp), vim.fs.normalize(vim.fn.getcwd()))
    end)

    -- Restore cwd so the next test does not inherit our tcd. `tcd -` is
    -- not a thing; the simplest reset is `cd` to the original path.
    pcall(vim.cmd.tcd, vim.fn.fnameescape(original_cwd))
    pcall(vim.fn.delete, tmp, "rf")
    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
    package.loaded["diffview.lib"] = nil

    if not ok then
      error(err)
    end
  end)

  it("leaves tab cwd alone when `sync_tab_cwd = false`", function()
    stub_overview()
    stub_emitter()
    stub_provider()

    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local original_cwd = vim.fn.getcwd()
    local win = vim.api.nvim_get_current_win()

    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return {
          _visible_entries = { { path = tmp } },
          winid = win,
          adapter = { ctx = { toplevel = tmp } },
        }
      end,
    }

    local ok, err = pcall(function()
      require("diffview-plus-agents").setup({ sidekick = { sync_tab_cwd = false } })
      make_overview_buffer()
      local before = vim.fn.getcwd()
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      assert.equals(before, vim.fn.getcwd())
    end)

    pcall(vim.cmd.tcd, vim.fn.fnameescape(original_cwd))
    pcall(vim.fn.delete, tmp, "rf")
    package.loaded["diffview-plus-agents.providers.sidekick"] = nil
    package.loaded["diffview.lib"] = nil

    if not ok then
      error(err)
    end
  end)
end)
