---Reset the resolver module between cases so each test runs against a
---freshly loaded module (clears the per-session cache and any lingering
---reader overrides).
local function reset_module()
  package.loaded["diffview-plus-agents.providers.model"] = nil
end

---Build a fake sidekick session table that mirrors the shape the provider
---sees. `pids` defaults to `{42}`; override per test when a parser needs to
---see a different argv/env.
---@param opts { tool?: string, pids?: integer[], id?: string, dump?: fun(self: table): string? }
local function session(opts)
  opts = opts or {}
  local s = {
    id = opts.id or "tmux 42",
    tool = { name = opts.tool or "claude", cmd = { opts.tool or "claude" } },
    pids = opts.pids or { 42 },
  }
  if opts.dump then
    s.dump = opts.dump
  end
  return s
end

---Install synthetic readers that look up pid -> argv / env from the given
---tables. The resolver then exercises its parser without touching `/proc`.
---`settings_by_path` keys the config reader so a parser that opens a
---settings file picks up the injected value for that path.
---@param argv_by_pid table<integer, string[]>
---@param env_by_pid table<integer, table<string,string>>
---@param pane_text? string
---@param settings_by_path? table<string, table>
local function with_readers(argv_by_pid, env_by_pid, pane_text, settings_by_path)
  local M = require("diffview-plus-agents.providers.model")
  M.__set_readers({
    cmdline = function(pid)
      return argv_by_pid[pid]
    end,
    environ = function(pid)
      return env_by_pid[pid]
    end,
    pane_text = function(_)
      return pane_text
    end,
    config = function(path)
      return settings_by_path and settings_by_path[path]
    end,
  })
  return M
end

describe("diffview-plus-agents.providers.model", function()
  before_each(reset_module)
  after_each(reset_module)

  describe("claude", function()
    it("parses `--model <name>` and shortens via the default shortener", function()
      local M = with_readers({ [42] = { "claude", "--model", "claude-sonnet-4-5-20251022" } }, {})
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("sonnet-4.5", info.model)
      assert.is_nil(info.effort)
    end)

    it("parses `--model=<name>`", function()
      local M = with_readers({ [42] = { "claude", "--model=claude-opus-4-5" } }, {})
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("opus-4.5", info.model)
    end)

    it("parses the `-m` alias", function()
      local M = with_readers({ [42] = { "claude", "-m", "claude-haiku-4-5" } }, {})
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("haiku-4.5", info.model)
    end)

    it("falls back to `ANTHROPIC_MODEL` when argv has no model flag", function()
      local M = with_readers(
        { [42] = { "claude" } },
        { [42] = { ANTHROPIC_MODEL = "claude-opus-4-5" } }
      )
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("opus-4.5", info.model)
    end)

    it("prefers argv over env when both carry a model", function()
      local M = with_readers(
        { [42] = { "claude", "--model", "claude-opus-4-5" } },
        { [42] = { ANTHROPIC_MODEL = "claude-sonnet-4-5" } }
      )
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("opus-4.5", info.model)
    end)

    it("returns empty when neither argv nor env carries a model", function()
      local M = with_readers({ [42] = { "claude" } }, { [42] = {} })
      local info = M.resolve(session({ tool = "claude" }))
      assert.is_nil(info.model)
      assert.is_nil(info.effort)
    end)

    it("parses `--effort <level>` on argv", function()
      local M = with_readers(
        { [42] = { "claude", "--model", "claude-opus-4-7", "--effort", "xhigh" } },
        {}
      )
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("opus-4.7", info.model)
      assert.equals("xhigh", info.effort)
    end)

    it("reads `effortLevel` from the user settings.json when argv has no `--effort`", function()
      local user_settings = vim.fn.expand("~/.claude/settings.json")
      local M = with_readers(
        { [42] = { "claude", "--model", "claude-opus-4-7" } },
        {},
        nil,
        { [user_settings] = { effortLevel = "xhigh" } }
      )
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("opus-4.7", info.model)
      assert.equals("xhigh", info.effort)
    end)

    it("prefers argv `--effort` over the settings.json `effortLevel`", function()
      local user_settings = vim.fn.expand("~/.claude/settings.json")
      local M = with_readers(
        { [42] = { "claude", "--model", "claude-opus-4-7", "--effort", "medium" } },
        {},
        nil,
        { [user_settings] = { effortLevel = "xhigh" } }
      )
      local info = M.resolve(session({ tool = "claude" }))
      assert.equals("medium", info.effort)
    end)

    it("project settings.json overrides the user settings.json", function()
      -- Claude layers per-project settings on top of user settings (git-style),
      -- so a `<cwd>/.claude/settings.json` entry wins over `~/.claude/...`.
      local user_settings = vim.fn.expand("~/.claude/settings.json")
      local project_settings = "/w/.claude/settings.json"
      local M = with_readers({ [42] = { "claude", "--model", "claude-opus-4-7" } }, {}, nil, {
        [user_settings] = { effortLevel = "xhigh" },
        [project_settings] = { effortLevel = "low" },
      })
      local s = session({ tool = "claude" })
      s.cwd = "/w"
      local info = M.resolve(s)
      assert.equals("low", info.effort)
    end)
  end)

  describe("codex", function()
    it("parses `--model` + `--reasoning-effort`", function()
      local M = with_readers({
        [42] = { "codex", "--model", "gpt-5", "--reasoning-effort", "high" },
      }, {})
      local info = M.resolve(session({ tool = "codex" }))
      assert.equals("gpt-5", info.model)
      assert.equals("high", info.effort)
    end)

    it("parses `-c key=value` pairs", function()
      -- codex-rs's config key for reasoning effort is the underscored
      -- `model_reasoning_effort`, not the dotted form.
      local M = with_readers({
        [42] = { "codex", "-c", "model_reasoning_effort=low", "-c", "model=gpt-5" },
      }, {})
      local info = M.resolve(session({ tool = "codex" }))
      assert.equals("gpt-5", info.model)
      assert.equals("low", info.effort)
    end)

    it("parses the `-m` short flag for model", function()
      local M = with_readers({ [42] = { "codex", "-m", "gpt-5.4" } }, {})
      local info = M.resolve(session({ tool = "codex" }))
      assert.equals("gpt-5.4", info.model)
    end)

    it("parses inline `--model=<name>` and `--reasoning-effort=<v>`", function()
      local M = with_readers({
        [42] = { "codex", "--model=gpt-5-mini", "--reasoning-effort=medium" },
      }, {})
      local info = M.resolve(session({ tool = "codex" }))
      assert.equals("gpt-5-mini", info.model)
      assert.equals("medium", info.effort)
    end)

    it("drops effort when model is unresolved", function()
      -- An `--reasoning-effort` with no model is nonsense for the status
      -- column: a lone `:high` looks like a model name.
      local M = with_readers({ [42] = { "codex", "--reasoning-effort", "high" } }, {})
      local info = M.resolve(session({ tool = "codex" }))
      assert.is_nil(info.model)
      assert.is_nil(info.effort)
    end)

    it("live mode reads the pane, which wins over argv", function()
      local M = with_readers(
        { [42] = { "codex", "--model", "gpt-5", "--reasoning-effort", "high" } },
        {},
        "status: model: gpt-5-mini  reasoning effort: low"
      )
      local info = M.resolve(
        session({
          tool = "codex",
          dump = function()
            return "ignored: readers override takes precedence"
          end,
        }),
        { live = true }
      )
      assert.equals("gpt-5-mini", info.model)
      assert.equals("low", info.effort)
    end)

    it("live mode does not scrape the pane when `live = false`", function()
      local M = with_readers({ [42] = { "codex" } }, {}, "model: gpt-5-mini  reasoning effort: low")
      local info = M.resolve(session({ tool = "codex" }))
      assert.is_nil(info.model)
    end)

    it("live mode picks the current status from the bottom, not stale scrollback", function()
      -- `session:dump()` runs `tmux capture-pane -p -S - -E -`, i.e., the
      -- full scrollback. `string.match` would pick the FIRST hit, which
      -- is launch-time output (or any older `/model` exchange) rather
      -- than the live status at the bottom of the viewport.
      local pane = table.concat({
        "model: gpt-4", -- stale launch banner, top of scrollback
        "reasoning effort: low", -- stale, from a prior /effort exchange
        string.rep("filler line\n", 40),
        "model: gpt-5", -- current status, bottom of viewport
        "reasoning effort: high",
      }, "\n")
      local M = with_readers({ [42] = { "codex" } }, {}, pane)
      local info = M.resolve(session({ tool = "codex" }), { live = true })
      assert.equals("gpt-5", info.model)
      assert.equals("high", info.effort)
    end)

    it("live mode ignores a stale match above the N-line tail window", function()
      -- Even without a bottom-of-pane match, we must not resurrect ancient
      -- scrollback: a mention 200 lines up should not surface as the
      -- current model. The regex falls through to argv/env instead.
      local lines = { "model: gpt-4", "reasoning effort: low" }
      for _ = 1, 200 do
        lines[#lines + 1] = "filler"
      end
      local pane = table.concat(lines, "\n")
      local M = with_readers(
        { [42] = { "codex", "--model", "gpt-5", "--reasoning-effort", "high" } },
        {},
        pane
      )
      local info = M.resolve(session({ tool = "codex" }), { live = true })
      assert.equals("gpt-5", info.model)
      assert.equals("high", info.effort)
    end)

    it("live mode does not mix a pane model with a stale argv effort", function()
      -- The user launched codex with `--reasoning-effort high`, then
      -- switched model via `/model gpt-5-mini`. The pane's status line
      -- shows the new model but not an effort indicator in this snapshot.
      -- Falling through to argv for effort would render
      -- `gpt-5-mini:high`, pretending effort is unchanged when we can't
      -- actually confirm that; drop effort when pane wins model.
      local M = with_readers(
        { [42] = { "codex", "--model", "gpt-5", "--reasoning-effort", "high" } },
        {},
        "model: gpt-5-mini"
      )
      local info = M.resolve(session({ tool = "codex" }), { live = true })
      assert.equals("gpt-5-mini", info.model)
      assert.is_nil(info.effort)
    end)

    it("live mode falls back to argv when the pane has no model match", function()
      -- If the pane dump is blank or the TUI has redrawn over its status,
      -- we still want to show the last-known launch-time info rather
      -- than nothing.
      local M = with_readers(
        { [42] = { "codex", "--model", "gpt-5", "--reasoning-effort", "high" } },
        {},
        "no status indicator anywhere in this pane"
      )
      local info = M.resolve(session({ tool = "codex" }), { live = true })
      assert.equals("gpt-5", info.model)
      assert.equals("high", info.effort)
    end)

    it("live mode parses the modern `<model> <effort> · Context` footer", function()
      -- Codex 0.17x+ dropped the labeled `model:` / `reasoning effort:`
      -- fields and renders a compact footer. `GPT-5.6-Sol xhigh ·
      -- Context 100% left · <path> · <uuid>` is the shape we must read.
      local M = with_readers(
        { [42] = { "codex" } },
        {},
        "GPT-5.6-Sol xhigh · Context 100% left · dir · path · uuid"
      )
      local info = M.resolve(session({ tool = "codex" }), { live = true })
      assert.equals("GPT-5.6-Sol", info.model)
      assert.equals("xhigh", info.effort)
    end)
  end)

  describe("pane ANSI stripping", function()
    it("tolerates SGR color escapes embedded between tokens of the codex footer", function()
      -- `tmux capture-pane -e` embeds per-token colour codes, so the real
      -- dump looks like `GPT-5.6-Sol xhigh\27[38;2;132;132;132m · ...`
      -- with an escape sequence sitting where my regex expects a space.
      -- Resolver should strip escapes before the parser sees them so the
      -- status line matches whether or not the terminal was coloured.
      local pane = "\27[49m  \27[38;2;246;226;183mGPT-5.6-Sol xhigh"
        .. "\27[38;2;132;132;132m · \27[38;2;242;181;144mContext 100% left\27[39m"
      -- The default pane reader strips ANSI; the test reader passes text
      -- straight through, so simulate that by routing through the real
      -- reader. Use session.dump = fn returning the escaped text.
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function()
          return { "codex" }
        end,
        environ = function()
          return {}
        end,
        -- Leave pane_text at its default so strip_ansi runs.
      })
      local info = M.resolve(
        session({
          tool = "codex",
          dump = function()
            return pane
          end,
        }),
        { live = true }
      )
      assert.equals("GPT-5.6-Sol", info.model)
      assert.equals("xhigh", info.effort)
    end)
  end)

  describe("antigravity (agy)", function()
    it("parses `--model` + `--effort` on argv", function()
      local M = with_readers(
        { [42] = { "agy", "--model", "gemini-4-neon-high", "--effort", "high" } },
        {}
      )
      local info = M.resolve(session({ tool = "antigravity", pids = { 42 } }))
      -- `gemini-4-neon-high` is agy's canonical id; the shortener leaves
      -- it alone (no Gemini/Claude prefix match on the id form). Users
      -- who care about `neon` run bare and rely on the pane scraper.
      assert.equals("gemini-4-neon-high", info.model)
      assert.equals("high", info.effort)
    end)

    it("live mode scrapes the pane footer `<model> · <effort>`", function()
      -- Agy renders `Gemini 4 Neon · high` in its footer, with a
      -- multi-word model name and no labels. The shortener collapses
      -- `Gemini 4 Neon` to `neon`.
      local pane = "? for shortcuts    Gemini 4 Neon · high"
      local M = with_readers({ [42] = { "agy" } }, {}, pane)
      local info = M.resolve(session({ tool = "antigravity", pids = { 42 } }), { live = true })
      assert.equals("neon", info.model)
      assert.equals("high", info.effort)
    end)
  end)

  describe("unknown and stub tools", function()
    it("returns empty for a tool with no parser entry", function()
      local M = with_readers({ [42] = { "mystery", "--model", "x" } }, {})
      local s = session({ tool = "mystery" })
      s.tool.name = "mystery"
      local info = M.resolve(s)
      assert.is_nil(info.model)
      assert.is_nil(info.effort)
    end)

    it("returns empty when readers throw", function()
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function()
          error("boom")
        end,
        environ = function()
          error("boom")
        end,
      })
      -- `pid_for_tool` catches the first failure; `resolve` wraps parser
      -- calls in pcall so a reader throwing beyond that is also absorbed.
      local info = M.resolve(session({ tool = "claude" }))
      assert.is_nil(info.model)
    end)
  end)

  describe("caching", function()
    it("reuses a cached result for the same `session.id`", function()
      local calls = 0
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function(_)
          calls = calls + 1
          return { "claude", "--model", "claude-sonnet-4-5" }
        end,
        environ = function(_)
          return {}
        end,
      })
      local s = session({ tool = "claude", id = "tmux 7" })
      M.resolve(s)
      M.resolve(s)
      M.resolve(s)
      -- `pid_for_tool` calls cmdline once per candidate pid (one pid here),
      -- then resolve reads argv once more directly. All three resolve calls
      -- after the first should come from the cache.
      assert.equals(2, calls)
    end)

    it("bypasses the cache in live mode so a mid-session `/model` switch is picked up", function()
      -- Regression: an earlier version cached the result unconditionally,
      -- so the pane scrape only ran on the first resolve and every later
      -- render returned the stale cached model. Live mode must re-scrape
      -- the pane on every call to catch a user's `/model` switch.
      local cmdline_calls, pane_calls = 0, 0
      local pane_text = "model: gpt-5 reasoning effort: high"
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function(_)
          cmdline_calls = cmdline_calls + 1
          return { "codex" }
        end,
        environ = function(_)
          return {}
        end,
        pane_text = function(_)
          pane_calls = pane_calls + 1
          return pane_text
        end,
      })
      local s = session({ tool = "codex", id = "tmux 11" })
      M.resolve(s, { live = true })
      pane_text = "model: gpt-5-mini reasoning effort: low"
      local second = M.resolve(s, { live = true })
      assert.equals("gpt-5-mini", second.model)
      assert.equals("low", second.effort)
      assert.equals(2, pane_calls)
    end)

    it("re-runs after `_invalidate_cache`", function()
      local calls = 0
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function(_)
          calls = calls + 1
          return { "claude", "--model", "claude-sonnet-4-5" }
        end,
        environ = function(_)
          return {}
        end,
      })
      local s = session({ tool = "claude", id = "tmux 7" })
      M.resolve(s)
      M._invalidate_cache()
      M.resolve(s)
      -- Two full resolutions, two cmdline reads each (pid_for_tool + argv).
      assert.equals(4, calls)
    end)

    it("invalidates the cache when the agent PID changes under a stable session id", function()
      -- Sidekick's tmux backend derives `session.id` from the pane PID,
      -- which survives a same-pane restart (user quits the agent and
      -- relaunches it in the same shell). A plain id-only cache would
      -- keep handing back the old agent's model indefinitely; keying
      -- on `(session.id, agent_pid)` catches the restart because the
      -- new agent process has a different PID.
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      local argv_by_pid = {
        [42] = { "claude", "--model", "claude-opus-4-5" },
        [43] = { "claude", "--model", "claude-sonnet-4-5" },
      }
      M.__set_readers({
        cmdline = function(pid)
          return argv_by_pid[pid]
        end,
        environ = function(_)
          return {}
        end,
      })
      local first = M.resolve(session({ tool = "claude", id = "tmux 7", pids = { 42 } }))
      assert.equals("opus-4.5", first.model)
      local second = M.resolve(session({ tool = "claude", id = "tmux 7", pids = { 43 } }))
      assert.equals("sonnet-4.5", second.model)
    end)
  end)

  describe("interpreter-hosted agents", function()
    it("matches the agent via argv[1] when argv[0] is an interpreter", function()
      -- `node /path/github-copilot-cli --model X` puts `node` in
      -- argv[0]; a plain `basename(argv[0])` check would miss. Look at
      -- argv[1] too so interpreter-hosted agents still bind.
      reset_module()
      local M = require("diffview-plus-agents.providers.model")
      M.__set_readers({
        cmdline = function(pid)
          if pid == 17 then
            return { "-bash" }
          end
          if pid == 42 then
            return { "/usr/bin/node", "/opt/copilot/bin/copilot", "--model", "gpt-5-mini" }
          end
        end,
        environ = function(_)
          return {}
        end,
      })
      local s = session({ tool = "copilot", pids = { 17, 42 } })
      s.tool = { name = "copilot", cmd = { "copilot" } }
      local info = M.resolve(s)
      assert.equals("gpt-5-mini", info.model)
    end)
  end)
end)
