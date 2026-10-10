---Reset `package.loaded` so each test re-evaluates the plugin and its
---sub-modules from source.
local function reset_modules()
  for _, m in ipairs({
    "diffview-plus-agents",
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

local function unstub()
  package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = nil
end

describe("diffview-plus-agents setup", function()
  before_each(reset_modules)
  after_each(unstub)

  it("errors (does not crash) when diffview-plus is not loaded", function()
    local notified
    local original = vim.notify
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end
    require("diffview-plus-agents").setup({ sidekick = {} })
    vim.notify = original

    assert.is_not_nil(notified)
    assert.equals(vim.log.levels.ERROR, notified.level)
    assert.equals("diffview+agents", notified.opts and notified.opts.title)
    assert.is_truthy(notified.msg:find("diffview-plus.nvim", 1, true))
  end)

  it("registers nothing when `sidekick` is omitted", function()
    local registered = stub_overview()
    require("diffview-plus-agents").setup({})
    require("diffview-plus-agents").setup()
    assert.equals(0, #registered)
  end)

  it("registers a sidekick status provider when `sidekick = {}` is set", function()
    local registered = stub_overview()
    require("diffview-plus-agents").setup({ sidekick = {} })
    assert.equals(1, #registered)
    assert.equals("function", type(registered[1]))
  end)

  it("passes `sidekick` options through to the status provider's factory", function()
    local registered = stub_overview()
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

  it("replaces the previous registration on each call", function()
    local registered = stub_overview()

    require("diffview-plus-agents").setup({ sidekick = {} })
    local first = registered[1]
    require("diffview-plus-agents").setup({ sidekick = {} })

    assert.equals(1, #registered)
    assert.is_not.equals(first, registered[1])
  end)

  it("tears down previous registration when `sidekick` is dropped on reload", function()
    local registered = stub_overview()

    require("diffview-plus-agents").setup({ sidekick = {} })
    assert.equals(1, #registered)

    require("diffview-plus-agents").setup({})
    assert.equals(0, #registered)
  end)
end)
