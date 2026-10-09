# diffview+coding agents

Coding-agent integration for [diffview+](https://github.com/dlyongemallo/diffview-plus.nvim).

The plugin fills the status column of `:DiffviewWorktreeOverview` with per-worktree agent state, so a glance at the overview tells you which worktrees have an agent attached and which one it is.

## Requirements

- Neovim ≥ 0.10.0.
- [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim) with the worktree overview feature (any build that defines `:DiffviewWorktreeOverview`).
- A status provider. [sidekick.nvim](https://github.com/folke/sidekick.nvim) is the recommended source and is the only built-in; see "Built-in providers" below. Alternatively, write your own inline provider (see "Writing your own").

## Install

With `lazy.nvim`:

```lua
{
  "dlyongemallo/diffview-plus-coding-agents.nvim",
  dependencies = {
    "dlyongemallo/diffview-plus.nvim",
    "folke/sidekick.nvim",   -- only if you want the `sidekick` built-in provider
  },
  opts = { providers = { "sidekick" } },
}
```

## Configuration

```lua
require("diffview-plus-coding-agents").setup({
  providers = {
    "sidekick",   -- name of a built-in provider; see "Built-in providers" below
  },
})
```

A provider is anything that resolves to a function `fn(entry) -> string?`, where `entry` is a `GitAdapter.WorktreeEntry` from diffview+. Return a short status string (one word or glyph plus a label is ideal) or `nil` to leave the entry blank. Any number of providers can be registered; their non-nil returns are joined with a space in the overview's status column.

Four forms are accepted:

```lua
require("diffview-plus-coding-agents").setup({
  providers = {
    "sidekick",                                      -- built-in, by name, with defaults

    { name = "sidekick", opts = { glyph = "*" } },   -- built-in with per-provider config

    function(entry)                                  -- bare function
      if vim.fn.isdirectory(entry.path .. "/.codex") == 1 then
        return "codex"
      end
    end,

    { name = "custom",                               -- inline spec with explicit status
      status = function(entry) return nil end },
  },
})
```

When a `{name, opts}` entry is given for a built-in, the plugin calls the provider's `setup(opts)` factory to produce a configured status closure. The accepted opts are per-provider; see each built-in's section below.

Calling `setup()` again replaces the previous registration, so configs can be reloaded without stacking.

## Built-in providers

### `sidekick`

Queries [sidekick.nvim](https://github.com/folke/sidekick.nvim)'s live session list via `sidekick.cli.state.get`, which sidekick builds from `/proc/<pid>/cwd` + `lsof` process discovery. For any session whose `cwd` matches the worktree path, the provider returns `<glyph><tool-name>` (e.g., `●claude`, `●codex`, `●copilot`).

sidekick ships `is_proc` matchers for twelve common agents (claude, codex, copilot, aider, gemini, grok, qwen, cursor, crush, opencode, amazon_q, pi), so one provider covers most of the terminal-based agent ecosystem. Status is derived from live process state, not log-file mtime heuristics, which makes it strictly more accurate than probing each agent's on-disk session format.

Zero cost when sidekick is not installed: the `require` fails cleanly and the provider returns nil.

Options (all optional):

```lua
{ name = "sidekick", opts = {
    glyph = "●",
}}
```

## Pairing with sidekick.nvim

The `sidekick` provider on its own just fills the status column. Opt into the full integration (auto-show the chat pane on `<CR>` from the overview, bind `<leader>aw` to focus the agent for the worktree you're on, bind `<leader>av` to send a visual selection to that worktree's agent) by adding a `sidekick` block to `setup`:

```lua
require("diffview-plus-coding-agents").setup({
  providers = { "sidekick" },
  sidekick = {},   -- enable the integration with defaults
})
```

All three bits are configurable. Set any field to `false` to skip that behaviour:

```lua
require("diffview-plus-coding-agents").setup({
  providers = { "sidekick" },
  sidekick = {
    show_on_enter = true,              -- auto-show agent pane on <CR>
    focus_keymap  = "<leader>aw",      -- or false to not bind
    send_keymap   = "<leader>av",      -- or false to not bind
  },
})
```

Omitting the `sidekick` key entirely (or setting it to `nil`) leaves the integration disabled; a subsequent setup without the key also tears down any previously installed handlers.

### How sessions get focused

Sidekick models two kinds of session: those it launched itself from inside nvim (backend = `terminal`), which run in a sidekick-managed floating window, and those it discovered elsewhere (backend = `tmux` / `zellij`), which run in whatever mux pane the user started them in. Sidekick's own `cli.show` / `cli.toggle` only know how to act on the first kind. The integration module bridges the gap:

| Scenario | `<CR>` (passive) | `<leader>aw` (active) |
|---|---|---|
| Sidekick-launched session (float) | opens the float, cursor stays on diff | opens the float |
| External tmux session | *no-op* (so the diff keeps focus) | `tmux switch-client` + `tmux select-window` to jump to the agent's pane |
| No matching session | `vim.notify` nothing-to-do | `vim.notify` nothing-to-do |

The `<CR>` handler stays passive on external tmux sessions on purpose: when you drill into a diff you don't want tmux to pull the rug out from under you. `<leader>aw` is the explicit "take me to the agent" gesture.

### Mechanics worth knowing

- The lookup matches sidekick's `State.get({})` entries by `session.cwd`, which covers both attached and tmux-backend-discovered sessions. Agents you launched directly in a bare tmux pane show up without any adoption step.
- The `show_on_enter` subscription is idempotent across reloads: a second `setup()` call detaches the previous subscription before installing a new one, so dev iteration doesn't stack handlers.
- `<leader>aw` works both on the overview (targets the row under the cursor) and inside a DiffView (targets the DiffView's own worktree). When neither context resolves, it `vim.notify`s instead of silently doing nothing.
- `<leader>av` only makes sense from inside a DiffView; the mapping is visual-mode only. Sidekick's `cli.send` works for both backends, so this one needs no special-casing.

## Writing your own

Providers run on every render of the worktree overview, so keep them cheap: a stat call or two on a well-known path is fine, but avoid shelling out. Errors are swallowed by diffview+ (`pcall`), so a broken provider will leave the row blank rather than take the overview down, but noisy failures will still log through `vim.notify`.
