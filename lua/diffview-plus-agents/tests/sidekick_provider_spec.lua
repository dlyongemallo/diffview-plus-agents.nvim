---Reset `package.loaded` so each test re-evaluates the provider against a
---freshly installed sidekick stub.
local function reset_module()
  package.loaded["diffview-plus-agents.providers.sidekick"] = nil
  package.loaded["diffview-plus-agents.providers.model"] = nil
end

---Invoke a `fun(entry, done)` provider and return the raw payload it
---hands to `done`. The provider emits segment lists (per diffview-plus's
---status contract); tests that care about rendered text pipe this
---through `render`, while a test that asserts on per-segment highlights
---can inspect the list directly.
---@param fn fun(entry: table?, done: fun(result: any))
---@param entry table?
---@return any
local function sync_call_raw(fn, entry)
  local result
  local called = false
  fn(entry, function(r)
    result = r
    called = true
  end)
  assert.is_true(called)
  return result
end

---Flatten a segment list into the concatenated text so the bulk of the
---assertions can still compare against plain strings. Returns `nil` for
---a nil/empty result (which the provider uses to tell the overview to
---skip the row).
---@param segments table?
---@return string?
local function render(segments)
  if segments == nil then
    return nil
  end
  local parts = {}
  for _, seg in ipairs(segments) do
    parts[#parts + 1] = seg.text
  end
  return table.concat(parts)
end

---Convenience: existing tests asserted on rendered strings; wrap the raw
---payload in `render` so those assertions survive the contract change.
---@param fn fun(entry: table?, done: fun(result: any))
---@param entry table?
---@return string?
local function sync_call(fn, entry)
  return render(sync_call_raw(fn, entry))
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

---Shortcut for building a fake sidekick state entry. `alive` defaults
---to true; pass `false` to simulate a session whose underlying process
---has exited but whose entry sidekick has not yet cleaned up (the
---`atime`-debounced close path). Mirrors sidekick's own state shape:
---`state.session` is the real `Session` object and carries `.tool`
---(assigned in `sidekick/cli/session/init.lua:86`), so the resolver
---receives a session that has the tool table it dispatches on. Dropping
---that from the fixture used to mask a "passing the wrong object"
---regression; keeping it means the provider's `.resolve(s.session, ...)`
---call is wired against the same shape that ships.
---@param tool string
---@param cwd string
---@param alive? boolean
---@param extra? table
local function session(tool, cwd, alive, extra)
  local tool_obj = { name = tool, cmd = { tool } }
  local entry = {
    tool = tool_obj,
    session = {
      cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")),
      tool = tool_obj,
      is_running = function()
        return alive ~= false
      end,
    },
  }
  if extra then
    for k, v in pairs(extra) do
      entry.session[k] = v
    end
  end
  return entry
end

---Install a fake resolver module so the provider spec stays decoupled from
---the real parser logic. The stub returns `info` verbatim from `resolve`.
---@param info DiffviewPlusAgents.ModelInfo
---@param on_resolve? fun(session: table, opts: table)
local function stub_resolver(info, on_resolve)
  package.loaded["diffview-plus-agents.providers.model"] = {
    resolve = function(s, o)
      if on_resolve then
        on_resolve(s, o)
      end
      return info or {}
    end,
    _invalidate_cache = function() end,
  }
end

describe("diffview-plus-agents.providers.sidekick", function()
  before_each(reset_module)
  after_each(unstub)

  it("returns nil when sidekick is not installed", function()
    reset_module()
    package.loaded["sidekick.cli.state"] = nil
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sync_call(sidekick.status, { path = "/anything" }))
  end)

  it("returns `<glyph><tool-name>` for a session matching the entry", function()
    stub_sidekick({ session("claude", "/my/wt") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("returns nil when no session's cwd matches the entry", function()
    stub_sidekick({ session("claude", "/some/other/wt") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("normalises paths so trailing slashes do not break the match", function()
    stub_sidekick({ session("codex", "/my/wt/") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●codex", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("reports every distinct tool with a session in the same cwd", function()
    stub_sidekick({
      session("claude", "/my/wt"),
      session("codex", "/my/wt"),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude ●codex", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("skips sessions whose backend reports `is_running() == false`", function()
    -- Sidekick's own debounce can keep a terminal in `M.terminals`
    -- after the agent process has exited, which `State.get` then
    -- still returns. The provider trusts `is_running` over mere
    -- membership so a dead agent clears the row immediately.
    stub_sidekick({
      session("claude", "/my/wt"),
      session("agy", "/my/wt", false),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("relabels `antigravity` as `agy` for the status column", function()
    -- Sidekick names the tool `antigravity` (matching the upstream module
    -- path) but the CLI is `agy`; the longer word dominates the status
    -- column, so render the short form.
    stub_sidekick({ session("antigravity", "/my/wt") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●agy", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("emits segments with a distinct highlight for the glyph", function()
    -- Visual chrome belongs to a different highlight group than the
    -- label so the row can read as "<faded glyph> <bright label>". This
    -- test pins the segment shape and the default highlight choice; a
    -- user who wants the glyph to pick up the status column's own
    -- highlight sets `glyph_hl = false` (covered below).
    stub_sidekick({ session("claude", "/w") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    local segments = sync_call_raw(sidekick.status, { path = "/w" })
    assert.same({ { text = "●", hl = "DiffviewNonText" }, { text = "claude" } }, segments)
  end)

  it("drops the glyph highlight when `glyph_hl = false`", function()
    stub_sidekick({ session("claude", "/w") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    local status = sidekick.setup({ glyph_hl = false })
    local segments = sync_call_raw(status, { path = "/w" })
    assert.same({ { text = "●" }, { text = "claude" } }, segments)
  end)

  it("separates multiple sessions with a text-only segment", function()
    -- A space-only segment keeps the width calculation accurate while
    -- letting the overview render the gap without any highlight. The
    -- previous plain-string contract spliced `" "` into the string; the
    -- new contract represents the same gap as its own segment.
    stub_sidekick({
      session("claude", "/w"),
      session("codex", "/w"),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    local segments = sync_call_raw(sidekick.status, { path = "/w" })
    assert.same({
      { text = "●", hl = "DiffviewNonText" },
      { text = "claude" },
      { text = " " },
      { text = "●", hl = "DiffviewNonText" },
      { text = "codex" },
    }, segments)
  end)

  it("deduplicates sessions whose tool name matches an earlier session's", function()
    stub_sidekick({
      session("claude", "/my/wt"),
      session("claude", "/my/wt"),
      session("codex", "/my/wt"),
    })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.equals("●claude ●codex", sync_call(sidekick.status, { path = "/my/wt" }))
  end)

  it("is nil-safe for entries that lack a usable path", function()
    stub_sidekick({})
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    assert.is_nil(sync_call(sidekick.status, nil))
    assert.is_nil(sync_call(sidekick.status, {}))
    assert.is_nil(sync_call(sidekick.status, { path = "" }))
  end)

  it("honours per-call opts: glyph", function()
    stub_sidekick({ session("claude", "/w") })
    local sidekick = require("diffview-plus-agents.providers.sidekick")
    local status = sidekick.setup({ glyph = "*" })
    assert.equals("*claude", sync_call(status, { path = "/w" }))
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
      sync_call(sidekick.status, { path = "/w" })
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
    sync_call(sidekick.status, { path = "/w" })
    sync_call(sidekick.status, { path = "/w" })
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
    sync_call(sidekick.status, { path = "/w" })
    sidekick._invalidate_cache()
    sync_call(sidekick.status, { path = "/w" })
    assert.equals(2, calls)
  end)

  describe("show_model / show_effort", function()
    it("appends `:<model>` when `show_model = true` and the resolver has one", function()
      stub_sidekick({ session("claude", "/w") })
      stub_resolver({ model = "sonnet-4.5" })
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true })
      assert.equals("●claude:sonnet-4.5", sync_call(status, { path = "/w" }))
    end)

    it("appends `:<effort>` only when both `show_effort` is on and a model resolved", function()
      stub_sidekick({ session("codex", "/w") })
      stub_resolver({ model = "gpt-5", effort = "high" })
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true, show_effort = true })
      assert.equals("●codex:gpt-5:high", sync_call(status, { path = "/w" }))
    end)

    it("drops effort when model is unresolved", function()
      stub_sidekick({ session("codex", "/w") })
      stub_resolver({ effort = "high" })
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true, show_effort = true })
      -- No model -> no suffix at all. The resolver dropped effort before
      -- returning, but even if it hadn't the provider must still refuse to
      -- render a lone `:high` which would read as a model name.
      assert.equals("●codex", sync_call(status, { path = "/w" }))
    end)

    it("renders the current `<glyph><tool>` unchanged when `show_model = false`", function()
      -- Regression guard: the no-op path must stay byte-identical to the
      -- shape users have been seeing since the feature pre-dated this
      -- change. The resolver stub asserts it is NEVER called.
      stub_sidekick({ session("claude", "/w") })
      local resolver_calls = 0
      stub_resolver({ model = "should-not-render" }, function()
        resolver_calls = resolver_calls + 1
      end)
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = false })
      assert.equals("●claude", sync_call(status, { path = "/w" }))
      assert.equals(0, resolver_calls)
    end)

    it("renders `<glyph><tool>` when `show_model` is enabled but no model is resolved", function()
      stub_sidekick({ session("claude", "/w") })
      stub_resolver({})
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true })
      assert.equals("●claude", sync_call(status, { path = "/w" }))
    end)

    it("normalises `show_model = true` to the resolver's `live = false`", function()
      stub_sidekick({ session("claude", "/w") })
      local seen_opts
      stub_resolver({ model = "sonnet-4.5" }, function(_, opts)
        seen_opts = opts
      end)
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true })
      sync_call(status, { path = "/w" })
      assert.equals(false, seen_opts.live)
    end)

    it("normalises `show_model = { enabled = true, live = true }` to `live = true`", function()
      stub_sidekick({ session("claude", "/w") })
      local seen_opts
      stub_resolver({ model = "sonnet-4.5" }, function(_, opts)
        seen_opts = opts
      end)
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = { enabled = true, live = true } })
      sync_call(status, { path = "/w" })
      assert.equals(true, seen_opts.live)
    end)

    it("`show_model = { enabled = false, live = true }` does not call the resolver", function()
      -- Live-without-enabled is nonsensical; the normalizer treats it as off.
      stub_sidekick({ session("claude", "/w") })
      local calls = 0
      stub_resolver({ model = "x" }, function()
        calls = calls + 1
      end)
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = { enabled = false, live = true } })
      assert.equals("●claude", sync_call(status, { path = "/w" }))
      assert.equals(0, calls)
    end)

    it("passes a session carrying its `.tool` to the resolver", function()
      -- Contract guard. Sidekick's `State.get_state` returns a state whose
      -- `.session` is the real `Session` object with `.tool` assigned in
      -- the Session constructor; the resolver dispatches on `session.tool.name`
      -- and would return `{}` for every row if the provider passed the
      -- state (`s`) instead of the session (`s.session`), or if the test
      -- fixture ever drifted away from sidekick's shape. The resolver
      -- stub tests stub `resolve` entirely, so without this guard a
      -- "s vs s.session" regression would ship green.
      stub_sidekick({ session("claude", "/w") })
      local seen_session
      stub_resolver({ model = "sonnet-4.5" }, function(s, _)
        seen_session = s
      end)
      local sidekick = require("diffview-plus-agents.providers.sidekick")
      local status = sidekick.setup({ show_model = true })
      sync_call(status, { path = "/w" })
      assert.is_table(seen_session)
      assert.is_table(seen_session.tool)
      assert.equals("claude", seen_session.tool.name)
    end)
  end)
end)
