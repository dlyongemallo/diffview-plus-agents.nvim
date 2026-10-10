---Reset `package.loaded` so each test re-evaluates the provider against a
---freshly installed sidekick stub.
local function reset_module()
  package.loaded["diffview-plus-agents.providers.sidekick"] = nil
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

describe("diffview-plus-agents.providers.sidekick", function()
  before_each(reset_module)
  after_each(unstub)

  it("returns nil when sidekick is not installed", function()
    reset_module()
    package.loaded["sidekick.cli.state"] = nil
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sidekick.status({ path = "/anything" }))
  end)

  it("returns `<glyph><tool-name>` for a session matching the entry", function()
    stub_sidekick({ session("claude", "/my/wt") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude", sidekick.status({ path = "/my/wt" }))
  end)

  it("returns nil when no session's cwd matches the entry", function()
    stub_sidekick({ session("claude", "/some/other/wt") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sidekick.status({ path = "/my/wt" }))
  end)

  it("normalises paths so trailing slashes do not break the match", function()
    stub_sidekick({ session("codex", "/my/wt/") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●codex", sidekick.status({ path = "/my/wt" }))
  end)

  it("reports every distinct tool with a session in the same cwd", function()
    stub_sidekick({
      session("claude", "/my/wt"),
      session("codex", "/my/wt"),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude ●codex", sidekick.status({ path = "/my/wt" }))
  end)

  it("deduplicates sessions whose tool name matches an earlier session's", function()
    stub_sidekick({
      session("claude", "/my/wt"),
      session("claude", "/my/wt"),
      session("codex", "/my/wt"),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude ●codex", sidekick.status({ path = "/my/wt" }))
  end)

  it("is nil-safe for entries that lack a usable path", function()
    stub_sidekick({})
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sidekick.status(nil))
    assert.is_nil(sidekick.status({}))
    assert.is_nil(sidekick.status({ path = "" }))
  end)

  it("honours per-call opts: glyph", function()
    stub_sidekick({ session("claude", "/w") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
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
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    for _ = 1, 10 do
      sidekick.status({ path = "/w" })
    end
    assert.equals(1, calls)
  end)

  it("still caches when a single State.get takes longer than the TTL", function()
    -- Regression: an earlier version stamped the cache time BEFORE calling
    -- `State.get`, so on a loaded system (where the scan can outlast its
    -- own TTL window) the just-populated cache looked already expired to
    -- the next caller. The overview then rescanned once per row, which on
    -- a 55-worktree view took tens of seconds. Simulate the slow scan
    -- with a `vim.uv.sleep` and assert the cache still survives it.
    local calls = 0
    package.loaded["sidekick.cli.state"] = {
      get = function()
        calls = calls + 1
        -- A one-millisecond sleep is enough to prove the ordering: any
        -- stamp taken before `State.get` returns would show the cache as
        -- older than TTL=500ms on an immediate follow-up call only if we
        -- also sleep for 500ms, which would slow the test. Instead,
        -- temporarily shorten the cache TTL via a different sentinel: we
        -- rely here on the fix stamping AFTER the scan, so even if the
        -- scan slept for the full TTL the cache is fresh on return.
        vim.uv.sleep(600)
        return { session("claude", "/w") }
      end,
    }
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    sidekick.status({ path = "/w" })
    sidekick.status({ path = "/w" })
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
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    sidekick.status({ path = "/w" })
    sidekick._invalidate_cache()
    sidekick.status({ path = "/w" })
    assert.equals(2, calls)
  end)
end)
