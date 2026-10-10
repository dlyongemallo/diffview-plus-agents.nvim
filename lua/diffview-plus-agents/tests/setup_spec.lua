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
  before_each(reset_modules)
  after_each(unstub)

  it("errors (does not crash) when diffview-plus is not loaded", function()
    -- Not stubbing the overview module simulates diffview+ being absent.
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
end)
