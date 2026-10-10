# diffview+agents

Agent integration for [diffview+](https://github.com/dlyongemallo/diffview-plus.nvim).

## Requirements

- Neovim ≥ 0.10.0.
- [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim) >= 0.39.

## Install

With `lazy.nvim`:

```lua
{
  "dlyongemallo/diffview-plus-agents.nvim",
  dependencies = { "dlyongemallo/diffview-plus.nvim" },
  config = function()
    require("diffview-plus-agents").setup({})
  end,
}
```
