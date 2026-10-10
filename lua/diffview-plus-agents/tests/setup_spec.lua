---Reset `package.loaded` so each test re-evaluates the plugin from source.
local function reset_module()
  package.loaded["diffview-plus-agents"] = nil
end

local function unstub()
  package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = nil
end

describe("diffview-plus-agents setup", function()
  before_each(reset_module)
  after_each(unstub)

  it("errors (does not crash) when diffview-plus is not loaded", function()
    -- Not stubbing the overview module simulates diffview+ being absent.
    local notified
    local original = vim.notify
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end
    require("diffview-plus-agents").setup({})
    vim.notify = original

    assert.is_not_nil(notified)
    assert.equals(vim.log.levels.ERROR, notified.level)
    -- Plugin name goes in the `title` (shown by notify UIs like
    -- `rcarriga/nvim-notify`); the message is the actual error.
    assert.equals("diffview+agents", notified.opts and notified.opts.title)
    assert.is_truthy(notified.msg:find("diffview-plus.nvim", 1, true))
  end)

  it("is a no-op when diffview-plus is loaded and no options are passed", function()
    package.loaded["diffview.scene.views.worktree_overview.worktree_overview_view"] = {}
    local original = vim.notify
    local notified = false
    vim.notify = function()
      notified = true
    end
    require("diffview-plus-agents").setup()
    require("diffview-plus-agents").setup({})
    vim.notify = original
    assert.is_false(notified)
  end)
end)
