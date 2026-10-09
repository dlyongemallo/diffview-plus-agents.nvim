---Reset `package.loaded` so each test re-evaluates the plugin from source.
local function reset_modules()
  package.loaded["diffview-plus-coding-agents"] = nil
  package.loaded["diffview-plus-coding-agents.providers.mock"] = nil
end

---Install a fake worktree-overview module in `package.loaded`. Returns the
---`registered` list so tests can assert what the plugin registered on it.
---@return (fun(entry: table): string?)[] registered
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

---Install a fake built-in provider module under the given name so the
---`{name = ...}` and `string` provider forms can be exercised without
---depending on a shipped provider.
---@param name string
---@param impl { status?: function, setup?: fun(opts: table?): function }
local function stub_builtin(name, impl)
  package.loaded["diffview-plus-coding-agents.providers." .. name] = impl
end

local function unstub()
  package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = nil
end

describe("diffview-plus-coding-agents setup", function()
  before_each(reset_modules)
  after_each(unstub)

  it("registers a bare function provider as-is", function()
    local registered = stub_overview()
    local called_with
    local fn = function(entry)
      called_with = entry
      return "x"
    end
    require("diffview-plus-coding-agents").setup({ providers = { fn } })

    assert.equals(1, #registered)
    assert.equals(fn, registered[1])
    assert.equals("x", registered[1]({ path = "/wt" }))
    assert.same({ path = "/wt" }, called_with)
  end)

  it("registers an inline table whose `status` is a function", function()
    local registered = stub_overview()
    local fn = function()
      return nil
    end
    require("diffview-plus-coding-agents").setup({
      providers = { { name = "custom", status = fn } },
    })

    assert.equals(1, #registered)
    assert.equals(fn, registered[1])
  end)

  it("resolves a built-in provider by name", function()
    local registered = stub_overview()
    local fn = function(entry)
      return "mock@" .. entry.path
    end
    stub_builtin("mock", { status = fn })

    require("diffview-plus-coding-agents").setup({ providers = { "mock" } })

    assert.equals(1, #registered)
    assert.equals(fn, registered[1])
  end)

  it("resolves a built-in by {name, opts} via its `setup` factory", function()
    local registered = stub_overview()
    local last_opts
    stub_builtin("mock", {
      setup = function(opts)
        last_opts = opts
        return function(entry)
          return (opts and opts.label or "default") .. "@" .. entry.path
        end
      end,
    })

    require("diffview-plus-coding-agents").setup({
      providers = {
        { name = "mock", opts = { label = "cfg" } },
      },
    })

    assert.equals(1, #registered)
    assert.same({ label = "cfg" }, last_opts)
    assert.equals("cfg@/wt", registered[1]({ path = "/wt" }))
  end)

  it("falls back to `.status` when a {name, opts} built-in has no `setup`", function()
    local registered = stub_overview()
    local fn = function()
      return "fallback"
    end
    stub_builtin("mock", { status = fn })

    require("diffview-plus-coding-agents").setup({
      providers = { { name = "mock", opts = { ignored = true } } },
    })

    assert.equals(1, #registered)
    assert.equals(fn, registered[1])
  end)

  it("replaces the previous registration on each call", function()
    local registered = stub_overview()
    local a, b = function() end, function() end

    require("diffview-plus-coding-agents").setup({ providers = { a } })
    assert.equals(1, #registered)
    assert.equals(a, registered[1])

    require("diffview-plus-coding-agents").setup({ providers = { b } })
    assert.equals(1, #registered)
    assert.equals(b, registered[1])
  end)

  it("skips malformed provider entries without taking the setup down", function()
    local registered = stub_overview()
    -- Swallow the vim.notify warnings so the test output isn't noisy.
    local original_notify = vim.notify
    vim.notify = function() end
    local good = function() end
    require("diffview-plus-coding-agents").setup({
      providers = { "not-a-real-builtin", 42, good },
    })
    vim.notify = original_notify

    assert.equals(1, #registered)
    assert.equals(good, registered[1])
  end)

  it("accepts no providers and registers nothing", function()
    local registered = stub_overview()
    require("diffview-plus-coding-agents").setup({})
    require("diffview-plus-coding-agents").setup()
    assert.equals(0, #registered)
  end)
end)
