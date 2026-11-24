# diffview+agents

Agent integration for [diffview+](https://github.com/dlyongemallo/diffview-plus.nvim).

The plugin fills the status column of `:DiffviewWorktreeOverview` with per-worktree agent state, so a glance at the overview tells you which worktrees have an agent attached and which one it is, and pairs that with keymaps that focus the agent for the worktree you're on or send the current visual selection to it.

## Requirements

- Neovim ≥ 0.10.0.
- [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim) >= 0.39.
- [sidekick.nvim](https://github.com/folke/sidekick.nvim).

## Install

With `lazy.nvim`:

```lua
{
  "dlyongemallo/diffview-plus-agents.nvim",
  dependencies = {
    "dlyongemallo/diffview-plus.nvim",
    "folke/sidekick.nvim",
  },
  opts = { sidekick = {} },
}
```

## Configuration

```lua
require("diffview-plus-agents").setup({
  sidekick = {
    glyph         = "●",             -- prefix in the status column (e.g., `●claude`)
    glyph_hl      = "DiffviewNonText", -- highlight group for the glyph; `false` to use the status column's default
    show_on_enter = true,            -- auto-show the agent pane on <CR> in the overview
    focus_keymap  = "<leader>aw",    -- focus the worktree's agent (false to skip)
    send_keymap   = "<leader>av",    -- send the current visual selection (false to skip)
    show_model    = false,           -- append `:<model>` after the tool name (see below)
    show_effort   = false,           -- append `:<effort>` after the model (when both are known)
  },
})
```

### Showing the model (and optionally effort)

With `show_model = true`, the status column renders `<glyph><tool>:<model>` (e.g., `●codex:gpt-5`). Add `show_effort = true` to also append the reasoning-effort setting where the agent surfaces it (`●codex:gpt-5:high`). The feature is off by default; enabling it is additive and the row keeps collapsing back to `<glyph><tool>` for any session whose model cannot be resolved.

`show_model` accepts a boolean shorthand or an explicit subtable:

| Value | Sources used | Catches a mid-session `/model` switch? |
|---|---|---|
| `false` (default) | none | none |
| `true` → `{ enabled = true, live = false }` | argv + env | no (launch-time only) |
| `{ enabled = true, live = true }` | pane + argv + env | yes (tmux backend only) |

Sources, in precedence order (pane wins over argv/env/config when enabled):

1. **argv**: reads the running agent's `/proc/<pid>/cmdline` for flags like `--model <name>` / `-m <name>` (claude/codex/copilot/agy), `--effort <level>` (claude/agy), and `--reasoning-effort <v>` / `-c model_reasoning_effort=<v>` (codex). Launch-time only.
2. **env**: reads `/proc/<pid>/environ` (via `sidekick.cli.procs.env`) for `ANTHROPIC_MODEL` and friends. Launch-time only.
3. **config** (claude only today): reads `effortLevel` from `~/.claude/settings.json`, with a per-worktree `<cwd>/.claude/settings.json` overlaying it. This is the only signal when the user launched bare and relies on claude's own settings file.
4. **pane** (opt-in via `live = true`): scrapes the tmux pane via `session:dump()` and parses a per-tool regex against the TUI footer. Only works for the `tmux` backend, and only against the last ~30 lines of the pane (so scrollback mentions do not win over the current status). When the pane yields a model, it is treated as authoritative: launch-time sources are not consulted for effort, since mixing a live model with a launch-time effort would lie about the agent's current state.

Caveats:

- The feature covers `claude`, `codex`, `copilot`, and `antigravity` (rendered as `agy` in the status column). `copilot` ships with a stub argv parser; contributors adding real flag conventions should extend `lua/diffview-plus-agents/providers/model.lua`.
- Windows: the resolver has no `/proc` and no `ps`, so it silently returns nothing and the row falls back to `<glyph><tool>`.
- Model names are collapsed by a built-in shortener: `claude-sonnet-4-5-20251022` → `sonnet-4.5`; agy's human-readable `Gemini 4 Neon` → `neon`; identifiers the rules do not touch pass through unchanged.

A single `sidekick` block controls both the status column and the pairing keymaps. Passing `sidekick = {}` enables everything with defaults; omitting the key leaves the plugin inert and tears down any previously installed handlers (useful across `setup` reloads).

Need a custom status function instead of what sidekick provides? Register it with diffview-plus directly via `require("diffview.scene.views.worktree_overview.worktree_overview_view").register_status_provider(fn)`. This plugin's job is to wire the specific tools it supports.

## How it works

### Status column

Queries sidekick's live session list via `sidekick.cli.state.get`, which sidekick builds from `/proc/<pid>/cwd` + `lsof` process discovery. For any session whose `cwd` matches a worktree, the overview renders `<glyph><tool-name>` (e.g., `●claude`, `●codex`, `●copilot`). sidekick ships `is_proc` matchers for twelve common agents, so one provider covers most of the terminal-based agent ecosystem.

The result of `State.get` is cached for 500ms so an N-worktree overview triggers one scan instead of N; the cache expires in time for the next overview open.

Zero cost when sidekick is not installed: the `require` fails cleanly and the provider returns nil.

### Keymaps

Sidekick models two kinds of session: those it launched itself from inside nvim (backend = `terminal`), which run in a sidekick-managed floating window, and those it discovered elsewhere (backend = `tmux` / `zellij`), which run in whatever mux pane the user started them in. Sidekick's own `cli.show` / `cli.toggle` only know how to act on the first kind. This plugin bridges the gap:

| Scenario | `<CR>` (passive) | `<leader>aw` (active) |
|---|---|---|
| Sidekick-launched session (float) | opens the float, cursor stays on diff | opens the float AND moves cursor into it |
| External tmux session | *no-op* (so the diff keeps focus) | `tmux switch-client` + `tmux select-window` + `tmux select-pane` to jump to the agent's pane |
| No matching session | *silent* | `vim.notify` nothing-to-do |
| Multiple sessions share the worktree | *silent* | `vim.ui.select` to disambiguate |

The `<CR>` handler stays passive on purpose: when you drill into a diff you don't want tmux to pull the rug out from under you. `<leader>aw` is the explicit "take me to the agent" gesture.

`<leader>av` only makes sense from inside a DiffView; the mapping is visual-mode only. On ambiguous worktrees (more than one agent in the same cwd) it also pops `vim.ui.select` so source code never silently leaves for the wrong agent.

### Mechanics worth knowing

- The lookup matches sidekick's `State.get({})` entries by `session.cwd`, which covers both attached and tmux-backend-discovered sessions. Agents you launched directly in a bare tmux pane show up without any adoption step.
- `show_on_enter`, the status column, and the keymaps are each idempotent across reloads: a second `setup()` call cleanly tears down the previous registration before installing the new one.
- `<leader>aw` works both on the overview (targets the row under the cursor) and inside a DiffView (targets the DiffView's own worktree). When neither context resolves, it `vim.notify`s instead of silently doing nothing.
- The keymap cleanup only unbinds a lhs if its live callback is still the one this plugin installed; a user who rebinds the same lhs after `setup` keeps their binding.
