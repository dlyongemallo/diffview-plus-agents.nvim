---Reset `package.loaded` so each test re-evaluates the provider against a
---freshly installed sidekick stub.
local function reset_module()
  package.loaded["diffview-plus-coding-agents.providers.sidekick"] = nil
end

---Install a fake `sidekick.cli.state` in `package.loaded`. `states` is the
---flat list `State.get(filter)` should return regardless of filter shape.
---@param states table[]
local function stub_sidekick(states)
  package.loaded["sidekick.cli.state"] = {
    get = function()
      return states
    end,
  }
end

local function unstub()
  package.loaded["sidekick.cli.state"] = nil
end

---Shortcut for building a fake sidekick state entry.
---@param tool string
---@param cwd string
local function session(tool, cwd)
  return {
    tool = { name = tool },
    session = { cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")) },
  }
end

describe("diffview-plus-coding-agents.providers.sidekick", function()
  before_each(reset_module)
  after_each(unstub)

  it("returns nil when sidekick is not installed", function()
    reset_module()
    package.loaded["sidekick.cli.state"] = nil
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    assert.is_nil(sidekick.status({ path = "/anything" }))
  end)

  it("returns `<glyph><tool-name>` for a session matching the entry", function()
    stub_sidekick({ session("claude", "/my/wt") })
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    assert.equals("●claude", sidekick.status({ path = "/my/wt" }))
  end)

  it("returns nil when no session's cwd matches the entry", function()
    stub_sidekick({ session("claude", "/some/other/wt") })
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    assert.is_nil(sidekick.status({ path = "/my/wt" }))
  end)

  it("normalises paths so trailing slashes do not break the match", function()
    stub_sidekick({ session("codex", "/my/wt/") })
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    assert.equals("●codex", sidekick.status({ path = "/my/wt" }))
  end)

  it("picks the first matching session when several run in the same cwd", function()
    stub_sidekick({
      session("claude", "/my/wt"),
      session("codex", "/my/wt"),
    })
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    -- The provider only returns one tool per call; it is the first in
    -- sidekick's list order. A user who wants multiple tools reported for
    -- the same worktree can register the provider twice with different
    -- glyphs, or write their own.
    assert.equals("●claude", sidekick.status({ path = "/my/wt" }))
  end)

  it("is nil-safe for entries that lack a usable path", function()
    stub_sidekick({})
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    assert.is_nil(sidekick.status(nil))
    assert.is_nil(sidekick.status({}))
    assert.is_nil(sidekick.status({ path = "" }))
  end)

  it("honours per-call opts: glyph", function()
    stub_sidekick({ session("claude", "/w") })
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    local status = sidekick.setup({ glyph = "*" })
    assert.equals("*claude", status({ path = "/w" }))
  end)

  it("calls sidekick's State.get at most once per short render window", function()
    -- The overview renders N rows in a tight loop, each invoking the
    -- provider. `State.get` scans tmux via `/proc` + `lsof`, so N calls
    -- amount to a visible pause. The provider caches the result and
    -- shares it across every row of a single render pass.
    local calls = 0
    package.loaded["sidekick.cli.state"] = {
      get = function()
        calls = calls + 1
        return { session("claude", "/w") }
      end,
    }
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    for _ = 1, 10 do
      sidekick.status({ path = "/w" })
    end
    assert.equals(1, calls)
  end)

  it("re-queries State.get after the cache is invalidated", function()
    local calls = 0
    package.loaded["sidekick.cli.state"] = {
      get = function()
        calls = calls + 1
        return { session("claude", "/w") }
      end,
    }
    local sidekick = require("diffview-plus-coding-agents.providers.sidekick")
    sidekick.status({ path = "/w" })
    sidekick._invalidate_cache()
    sidekick.status({ path = "/w" })
    assert.equals(2, calls)
  end)
end)
