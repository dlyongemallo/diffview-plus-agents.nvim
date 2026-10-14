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
    show_on_enter = true,            -- auto-show the agent pane on <CR> in the overview
    focus_keymap  = "<leader>aw",    -- focus the worktree's agent (false to skip)
    send_keymap   = "<leader>av",    -- send the current visual selection (false to skip)
  },
})
```

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
