# diffview+agents

Agent integration for [diffview+](https://github.com/dlyongemallo/diffview-plus.nvim).

The plugin fills the status column of `:DiffviewWorktreeOverview` with per-worktree agent state, so a glance at the overview tells you which worktrees have an agent attached and which one it is.

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
    glyph = "●",   -- prefix in the status column (e.g., `●claude`)
  },
})
```

Passing `sidekick = {}` enables the integration with defaults; omitting the key leaves the plugin inert.

## How it works

### Status column

Queries sidekick's live session list via `sidekick.cli.state.get`, which sidekick builds from `/proc/<pid>/cwd` + `lsof` process discovery. For any session whose `cwd` matches a worktree, the overview renders `<glyph><tool-name>` (e.g., `●claude`, `●codex`, `●copilot`). sidekick ships `is_proc` matchers for twelve common agents, so one provider covers most of the terminal-based agent ecosystem.

The result of `State.get` is cached for 500ms so an N-worktree overview triggers one scan instead of N; the cache expires in time for the next overview open.

Zero cost when sidekick is not installed: the `require` fails cleanly and the provider returns nil.
