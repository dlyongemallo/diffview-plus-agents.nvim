local M = {}

---@class DiffviewPlusAgents.ModelInfo
---@field model? string
---@field effort? string

---@class DiffviewPlusAgents.ModelResolverOpts
---@field live? boolean # Also scrape the tmux pane; requires a session with a `dump` method.

---Collapse long upstream model identifiers so they fit the status column.
---Machine ids are normalised (`claude-sonnet-4-5-20251022` -> `sonnet-4.5`;
---`claude-opus-4-5` -> `opus-4.5`); case is preserved for identifiers the
---rules do not touch (`GPT-5.6-Sol` stays mixed-case). Human-readable
---pane labels like antigravity's `Gemini 4 Neon` are collapsed to just
---their codename (`neon`); `Claude Opus 5.5` becomes `opus-5.5`.
---@param raw string
---@return string
local function shorten_model(raw)
  if type(raw) ~= "string" or raw == "" then
    return raw
  end
  local s = raw
  -- Strip vendor/generation prefixes from human-readable pane labels, so
  -- that only the distinguishing suffix remains; also lowercase the
  -- result in that case to match the rest of the status column.
  local lowered = false
  local stripped = s:gsub("^Gemini%s+[%d%.]+%s+", "")
  if stripped ~= s then
    s, lowered = stripped, true
  end
  stripped = s:gsub("^Claude%s+", "")
  if stripped ~= s then
    s, lowered = stripped, true
  end
  -- Machine-id normalisations: drop the `claude-` vendor prefix, trim a
  -- trailing `-YYYYMMDD` date snapshot, and collapse a terminal `A-B`
  -- version segment to `A.B` (`opus-4-5` -> `opus-4.5`).
  s = s:gsub("^claude%-", "")
  s = s:gsub("%-%d%d%d%d%d%d%d%d$", "")
  s = s:gsub("(%d+)%-(%d+)$", "%1.%2")
  s = s:gsub("%s+", "-")
  if lowered then
    s = s:lower()
  end
  return s
end

---Read `/proc/<pid>/cmdline` on Linux, with a `ps -o command=` fallback for
---macOS. Returns the argv as a list of strings. Any failure returns nil;
---`resolve` treats that as "no argv for this pid".
---@param pid integer
---@return string[]?
local function default_cmdline(pid)
  if not pid then
    return nil
  end
  local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "r")
  if f then
    local data = f:read("*all")
    f:close()
    if data and data ~= "" then
      local argv = vim.split(data, "\0", { plain = true })
      if argv[#argv] == "" then
        table.remove(argv)
      end
      return argv
    end
  end
  if vim.fn.has("win32") == 1 or vim.fn.executable("ps") ~= 1 then
    return nil
  end
  local out = vim.fn.systemlist({ "ps", "-o", "command=", "-p", tostring(pid) })
  if vim.v.shell_error ~= 0 or type(out) ~= "table" or #out == 0 then
    return nil
  end
  local line = out[1]
  if type(line) ~= "string" or line == "" then
    return nil
  end
  return vim.split(vim.trim(line), "%s+")
end

---Delegate to `sidekick.cli.procs.env`, which already handles Linux `/proc`
---and macOS `ps eww`. Wrapped in pcall so a missing module or permission
---error never surfaces.
---@param pid integer
---@return table<string,string>?
local function default_environ(pid)
  if not pid then
    return nil
  end
  local ok, procs = pcall(require, "sidekick.cli.procs")
  if not ok or type(procs) ~= "table" or type(procs.env) ~= "function" then
    return nil
  end
  local ok2, env = pcall(procs.env, pid)
  if not ok2 or type(env) ~= "table" then
    return nil
  end
  return env
end

---Strip ANSI CSI escapes (SGR colors, cursor moves, etc.) from a string.
---Sidekick's `session:dump()` runs `tmux capture-pane -e`, which embeds
---color codes mid-line; without this the per-tool pane regexes would
---see tokens like `xhigh\27[38;2;132;132;132m · Context` and never
---match the ` · ` separator.
---@param text string
---@return string
local function strip_ansi(text)
  text = text:gsub("\27%[[%d;:?]*[A-Za-z]", "")
  text = text:gsub("\27", "")
  return text
end

---Capture the session's pane buffer via `session:dump()`. Only tmux-backed
---sessions ship `dump`; other backends return nil silently.
---@param session table
---@return string?
local function default_pane_text(session)
  if not session or type(session.dump) ~= "function" then
    return nil
  end
  local ok, text = pcall(session.dump, session)
  if not ok or type(text) ~= "string" then
    return nil
  end
  return strip_ansi(text)
end

---Load a JSON config file. Returns the decoded table, or nil when the file
---is missing, empty, unreadable, or not valid JSON. Agents like claude keep
---launch-time state (effort level, selected model, etc.) in a settings
---file rather than argv, so this is the only signal available when the
---user launched the agent bare.
---@param path string
---@return table?
local function default_config(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*all")
  f:close()
  if not data or data == "" then
    return nil
  end
  local ok, parsed = pcall(vim.json.decode, data)
  if not ok or type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

M._readers = {
  cmdline = default_cmdline,
  environ = default_environ,
  pane_text = default_pane_text,
  config = default_config,
}

---Test hook: swap one or more readers for a synthetic implementation.
---`__reset_readers` restores the defaults. Prefixed with `__` to signal the
---API is not for ordinary callers. `readers` is a subset of
---`{ cmdline, environ, pane_text }`.
---@param readers table
function M.__set_readers(readers)
  if readers.cmdline then
    M._readers.cmdline = readers.cmdline
  end
  if readers.environ then
    M._readers.environ = readers.environ
  end
  if readers.pane_text then
    M._readers.pane_text = readers.pane_text
  end
  if readers.config then
    M._readers.config = readers.config
  end
end

function M.__reset_readers()
  M._readers.cmdline = default_cmdline
  M._readers.environ = default_environ
  M._readers.pane_text = default_pane_text
  M._readers.config = default_config
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  return path:match("([^/\\]+)$") or path
end

---Pick the PID whose argv[0] (or argv[1]) basename matches `tool.cmd[1]`.
---The first entry of `session.pids` is often a shell wrapper (tmux pane
---shell, or a `sh -c` under the terminal backend) so blindly using it
---would read the wrong argv. Interpreter-hosted agents launched as
---`node /path/foo-cli --model X` put the interpreter in argv[0] and the
---script in argv[1], so both slots are checked. Falls back to `pids[1]`
---when no match is found.
---@param session table
---@param tool table?
---@return integer?
local function pid_for_tool(session, tool)
  if not session then
    return nil
  end
  local pids = session.pids
  if type(pids) ~= "table" or #pids == 0 then
    return nil
  end
  local target = tool and tool.cmd and tool.cmd[1]
  target = target and basename(target)
  if not target then
    return pids[1]
  end
  for _, pid in ipairs(pids) do
    local ok, argv = pcall(M._readers.cmdline, pid)
    if ok and argv then
      if argv[1] and basename(argv[1]) == target then
        return pid
      end
      if argv[2] and basename(argv[2]) == target then
        return pid
      end
    end
  end
  return pids[1]
end

---`M._readers.cmdline`/`environ` wrapped so a throwing reader returns nil
---rather than aborting `resolve`. The default readers never throw, but
---tests inject readers that do, and a future reader (e.g. an external
---`ps` call) could legitimately fail.
---@param pid integer
---@return string[]?
local function safe_cmdline(pid)
  local ok, argv = pcall(M._readers.cmdline, pid)
  return ok and argv or nil
end

---@param pid integer
---@return table<string,string>?
local function safe_environ(pid)
  local ok, env = pcall(M._readers.environ, pid)
  return ok and env or nil
end

-- Per-tool parsers. Each returns `{ model?, effort? }` from the given source.
-- A parser missing a signal returns an empty table; `resolve` merges fields
-- across sources without overwriting earlier wins.

local function arg_pair(a, prefix)
  if type(a) ~= "string" then
    return nil
  end
  if a == prefix then
    return "flag"
  end
  if a:sub(1, #prefix + 1) == prefix .. "=" then
    return "inline", a:sub(#prefix + 2)
  end
  return nil
end

local function parse_claude_argv(argv)
  local info = {}
  for i = 1, #argv do
    local mk, mv = arg_pair(argv[i], "--model")
    local ek, ev = arg_pair(argv[i], "--effort")
    if mk == "flag" and argv[i + 1] then
      info.model = argv[i + 1]
    elseif mk == "inline" then
      info.model = mv
    elseif argv[i] == "-m" and argv[i + 1] then
      info.model = argv[i + 1]
    elseif ek == "flag" and argv[i + 1] then
      info.effort = argv[i + 1]
    elseif ek == "inline" then
      info.effort = ev
    end
  end
  return info
end

local function parse_claude_env(env)
  return { model = env.ANTHROPIC_MODEL or env.CLAUDE_MODEL }
end

---Read claude's settings.json for the persisted `effortLevel`. The CLI
---writes this when the user picks an effort via `/effort` (or sets it in
---the UI), and the value survives relaunches. Layering mirrors claude's
---own order: user settings (`~/.claude/settings.json`) first, then
---project settings (`<session.cwd>/.claude/settings.json`) overlaying
---it, so a per-repo override wins. Local-only overrides
---(`settings.local.json`) are not consulted here; users who need them
---can set `--effort` on argv instead.
---@param session table
---@return DiffviewPlusAgents.ModelInfo
local function parse_claude_config(session)
  local info = {}
  local paths = { vim.fn.expand("~/.claude/settings.json") }
  if session and type(session.cwd) == "string" and session.cwd ~= "" then
    paths[#paths + 1] = session.cwd .. "/.claude/settings.json"
  end
  for _, path in ipairs(paths) do
    local ok, cfg = pcall(M._readers.config, path)
    if
      ok
      and type(cfg) == "table"
      and type(cfg.effortLevel) == "string"
      and cfg.effortLevel ~= ""
    then
      info.effort = cfg.effortLevel
    end
  end
  return info
end

---Return the last `n` newline-separated lines of `text`, without splitting
---the whole string. Scans backward from the end until `n` newlines have
---been crossed; falls through to the full string when there are fewer.
---Used to bound pane regexes to the live viewport instead of the full
---tmux scrollback that `session:dump()` returns.
---@param text string
---@param n integer
---@return string
local function tail_lines(text, n)
  if type(text) ~= "string" or n <= 0 then
    return text or ""
  end
  local count = 0
  for i = #text, 1, -1 do
    if text:byte(i) == 10 then
      count = count + 1
      if count == n then
        return text:sub(i + 1)
      end
    end
  end
  return text
end

---Return the LAST match of `pattern` in `text`, or nil. `string.match`
---returns the first; for a TUI status line that sits at the bottom of the
---viewport that's exactly wrong, since any stale mention higher up in the
---captured scrollback (launch banner, earlier `/model` output, a prose
---reply from the agent) would win over the current status.
---@param text string
---@param pattern string
---@return string?
local function match_last(text, pattern)
  local last
  for m in text:gmatch(pattern) do
    last = m
  end
  return last
end

---Best-effort scrape of the claude TUI chrome. Matches `Model: <name>`
---lines; the TUI's layout has changed across versions, so this will miss
---many cases until a contributor extends it.
---@param text string
---@return DiffviewPlusAgents.ModelInfo
local function parse_claude_pane(text)
  local tail = tail_lines(text, 30)
  return { model = match_last(tail, "[Mm]odel:%s*([%w%-%.]+)") }
end

local function parse_codex_argv(argv)
  local info = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local mk, mv = arg_pair(a, "--model")
    local ek, ev = arg_pair(a, "--reasoning-effort")
    if mk == "flag" and argv[i + 1] then
      info.model = argv[i + 1]
      i = i + 2
    elseif mk == "inline" then
      info.model = mv
      i = i + 1
    elseif a == "-m" and argv[i + 1] then
      info.model = argv[i + 1]
      i = i + 2
    elseif ek == "flag" and argv[i + 1] then
      info.effort = argv[i + 1]
      i = i + 2
    elseif ek == "inline" then
      info.effort = ev
      i = i + 1
    elseif a == "-c" and type(argv[i + 1]) == "string" then
      -- Codex's TOML overrides: `-c model="o3"` and
      -- `-c model_reasoning_effort=low`. The effort key name tracks
      -- codex-rs's core config schema, which uses an underscored flat
      -- key rather than the dotted `reasoning.effort` form.
      local k, v = argv[i + 1]:match("^([^=]+)=(.+)$")
      if k == "model" then
        info.model = v
      elseif k == "model_reasoning_effort" then
        info.effort = v
      end
      i = i + 2
    else
      i = i + 1
    end
  end
  return info
end

-- `OPENAI_MODEL`/`OPENAI_REASONING_EFFORT` are not documented codex env
-- vars at the time of writing; the entry is here so a user who exports them
-- for other tooling still gets a result. Argv is the reliable signal.
local function parse_codex_env(env)
  return { model = env.OPENAI_MODEL, effort = env.OPENAI_REASONING_EFFORT }
end

local function parse_codex_pane(text)
  local tail = tail_lines(text, 30)
  -- Modern codex (0.17x+) footer renders the status as
  --   `<model> <effort> · Context N% left · <dir> · <path> · <uuid>`
  -- so the two tokens immediately before the first ` · Context` are the
  -- live model and effort. Earlier builds used labeled fields, kept here
  -- as a fallback for users on older versions.
  local model, effort
  for m, e in tail:gmatch("([%w%-%.]+)%s+(%w+)%s+·%s+Context") do
    model, effort = m, e
  end
  model = model or match_last(tail, "[Mm]odel:%s*([%w%-%.]+)")
  effort = effort or match_last(tail, "[Rr]easoning [Ee]ffort:%s*(%w+)")
  return { model = model, effort = effort }
end

-- Speculative: GitHub Copilot CLI does not have a documented model flag yet.
-- The stub matches `--model <name>` so users on a future release get a hit
-- without further changes; otherwise this returns empty.
local function parse_copilot_argv(argv)
  local info = {}
  for i = 1, #argv do
    if argv[i] == "--model" and argv[i + 1] then
      info.model = argv[i + 1]
    end
  end
  return info
end

local function parse_copilot_env(_)
  return {}
end

local function parse_copilot_pane(_)
  return {}
end

-- Google Antigravity CLI. The binary is named `agy` but sidekick's PR
-- registers the tool as `antigravity` (matching the upstream module path),
-- so `s.tool.name` is `antigravity` and the parser key must match. Argv
-- flags mirror claude's: `--model <id>` and `--effort <level>`. The
-- live status footer renders model + effort as
--   `? for shortcuts    Gemini 4 Neon · high`
-- with model potentially multi-word; parse that as "whatever precedes
-- the final ` · <word>` on a footer line".
local function parse_antigravity_argv(argv)
  local info = {}
  for i = 1, #argv do
    local mk, mv = arg_pair(argv[i], "--model")
    local ek, ev = arg_pair(argv[i], "--effort")
    if mk == "flag" and argv[i + 1] then
      info.model = argv[i + 1]
    elseif mk == "inline" then
      info.model = mv
    elseif ek == "flag" and argv[i + 1] then
      info.effort = argv[i + 1]
    elseif ek == "inline" then
      info.effort = ev
    end
  end
  return info
end

local function parse_antigravity_env(_)
  return {}
end

local function parse_antigravity_pane(text)
  local tail = tail_lines(text, 30)
  local model, effort
  for line in tail:gmatch("[^\n]+") do
    -- Agy's TUI right-aligns the status on the footer line by inserting a
    -- wide padding gap between unrelated left-side hints (`? for shortcuts`)
    -- and the live status (`Gemini 4 Neon · high`). Anchor on the ` · <effort>`
    -- tail, then drop anything before the last 2+ space gap so the padded
    -- hints never bleed into the model name.
    local before_sep, e = line:match("^(.*)%s+·%s+(%w+)%s*$")
    if before_sep and e then
      local raw_model = before_sep:match("%s%s+(.+)$") or before_sep
      raw_model = vim.trim(raw_model)
      if raw_model ~= "" then
        model, effort = raw_model, e
      end
    end
  end
  return { model = model, effort = effort }
end

M._parsers = {
  claude = {
    argv = parse_claude_argv,
    env = parse_claude_env,
    pane = parse_claude_pane,
    config = parse_claude_config,
  },
  codex = { argv = parse_codex_argv, env = parse_codex_env, pane = parse_codex_pane },
  copilot = { argv = parse_copilot_argv, env = parse_copilot_env, pane = parse_copilot_pane },
  antigravity = {
    argv = parse_antigravity_argv,
    env = parse_antigravity_env,
    pane = parse_antigravity_pane,
  },
}

---Per-session cache for launch-time resolutions only. Argv and env are
---immutable for a given PID until the process execs, so a hit is safe
---as long as the agent process has not changed. Entries carry a hash
---of `session.pids` so a same-pane restart (user quits the agent and
---relaunches it in the same shell) invalidates without needing to
---re-scan argv: sidekick's tmux backend keeps `session.id` stable
---across restarts (it derives from the pane PID), but the agent's own
---PID appears fresh in `session.pids` on the next `State.get` scan.
---Live-mode resolutions bypass the cache entirely because the whole
---point of live mode is to pick up a model the user switched to via
---the TUI's own `/model` command. The provider wires its
---`_invalidate_cache` to also clear this one so hard events
---(`SidekickCliAttach`/`Detach`, `TermClose`) do not leave a stale
---entry pointing at a reused id.
---@type table<string, { pids_hash: string, info: DiffviewPlusAgents.ModelInfo }>
M._cache = {}

---Order-insensitive hash of a session's pid list for cache invalidation.
---`table.sort` on a copy so sidekick's scan order (which can vary) does
---not thrash the cache, and `table.concat` for the actual hash.
---@param pids integer[]?
---@return string
local function pids_hash(pids)
  if type(pids) ~= "table" then
    return ""
  end
  local copy = {}
  for i, p in ipairs(pids) do
    copy[i] = p
  end
  table.sort(copy)
  return table.concat(copy, ",")
end

function M._invalidate_cache()
  M._cache = {}
end

---Resolve the model (and optionally effort) for a sidekick session.
---Returns an empty table when the tool is unknown, the session carries no
---PIDs, every reader fails, or the parsers find nothing. Never throws.
---@param session table
---@param opts? DiffviewPlusAgents.ModelResolverOpts
---@return DiffviewPlusAgents.ModelInfo
function M.resolve(session, opts)
  if type(session) ~= "table" then
    return {}
  end
  opts = opts or {}
  local tool = session.tool
  if type(tool) ~= "table" then
    return {}
  end
  local parsers = M._parsers[tool.name]
  if not parsers then
    return {}
  end

  local info = {}
  local function merge(src)
    if type(src) ~= "table" then
      return
    end
    if info.model == nil and type(src.model) == "string" and src.model ~= "" then
      info.model = src.model
    end
    if info.effort == nil and type(src.effort) == "string" and src.effort ~= "" then
      info.effort = src.effort
    end
  end
  local function try(fn, arg)
    if type(fn) ~= "function" or arg == nil then
      return
    end
    local ok, res = pcall(fn, arg)
    if ok then
      merge(res)
    end
  end

  -- Pane first (live mode only): the whole point of live mode is to
  -- show what the TUI is currently rendering, and a successful pane
  -- parse is authoritative. Running it before any per-pid read means a
  -- pane-hit never pays for argv/env lookups the result would discard,
  -- which matters on macOS where `sidekick.cli.procs.env` shells out
  -- to `ps eww` per session. Mixing pane model with argv effort would
  -- also lie: a user who switched `/model` mid-session may have also
  -- switched effort, so showing the launch-time effort next to the
  -- new model misrepresents state.
  if opts.live then
    local ok_pane, pane = pcall(M._readers.pane_text, session)
    if ok_pane and type(pane) == "string" then
      local ok2, pane_info = pcall(parsers.pane, pane)
      if ok2 and type(pane_info) == "table" and pane_info.model then
        info.model = pane_info.model
        info.effort = pane_info.effort
      end
    end
  end

  -- Launch-time fallback: argv, env, and per-tool config files (e.g.,
  -- claude's `~/.claude/settings.json`). Only entered when the pane
  -- did not resolve a model (live mode was off, pane dump failed, or
  -- the TUI had redrawn over its status).
  local launch_time = false
  local hash
  if not info.model then
    launch_time = true
    local cache_key = (not opts.live) and session.id or nil
    hash = pids_hash(session.pids)
    local cached = cache_key and M._cache[cache_key]
    if cached and cached.pids_hash == hash then
      return cached.info
    end
    local pid = pid_for_tool(session, tool)
    try(parsers.argv, pid and safe_cmdline(pid) or nil)
    try(parsers.env, pid and safe_environ(pid) or nil)
    try(parsers.config, session)
  end

  if info.model then
    local short = shorten_model(info.model)
    if short ~= "" then
      info.model = short
    end
  end
  if not info.model then
    info.effort = nil
  end

  -- Only the launch-time branch populates the cache; pane-resolved
  -- results would go stale the moment the user switches `/model`
  -- again, so they are never stored.
  if launch_time and not opts.live and session.id then
    M._cache[session.id] = { pids_hash = hash, info = info }
  end
  return info
end

return M
