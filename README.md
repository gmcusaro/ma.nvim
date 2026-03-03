# Ma.nvim

<div align="center">
<img width="513" height="513" alt="Image" src="https://github.com/user-attachments/assets/979f03be-a134-47d4-a98e-272656dfa3ef" />
</div>

A minimal knowledge layer for Markdown in [Neovim](https://neovim.io).

Ma.nvim lets structure emerge from filenames rather than directories. Notes live in a flat filesystem, while hierarchy is inferred through dot-separated segments and hyphenated words.

Inspired by [Dendron](https://www.dendron.so) and [Obsidian](https://obsidian.md), Ma provides vault-scoped navigation and safe file operations — without imposing folder-based structure.

## Why *Ma*?

**Ma** (間) is a Japanese concept often translated as *interval* or *space between*.

It does not mean emptiness as absence.
It refers to meaningful space — the gap that makes relation possible.

In Ma.nvim, structure is not imposed through folders.
It emerges in the intervals:

- Dots define hierarchy.
- Hyphens define words.
- Meaning lives in the space between segments.

Ma also implies time — the pause between actions, the space we take to write, reflect, and connect ideas in plain text.

## Getting Started

- [Neovim (>= 0.11.0)](https://github.com/neovim/neovim/releases/tag/v0.11.0) or the lastest neovim relesed.

### Required dependencies

- [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [Telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

### Optional dependencies

- [devicons](https://github.com/nvim-tree/nvim-web-devicons) (icons).
- [Marksman (Markdown LSP)](https://github.com/artempyanykh/marksman) — Enables LSP-powered Markdown navigation (e.g. `gd` on links, semantic link resolution, document symbols).

## Installation

I recommend pinning to the latest release
[tag](https://github.com/gmcusaro/ma.nvim/tags),
e.g. using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    'gmcusaro/ma.nvim', version = '*',
    dependencies = {
        'nvim-lua/plenary.nvim',
        'nvim-telescope/telescope.nvim',
        -- optional but recommended
        { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
        { "nvim-tree/nvim-web-devicons", otps = {} }
    }
}
```

## Setup

Ma need a vault - a root folder containing Markdown notes.

```lua
opts = {
    vaults = {
        { name = "My brain", path ="~/My_brain"}
    }
}
```

## Usage

Run `:Ma` to parse your notes by filename segments (`.` for hierarchy, `-` for words) and explore them through Telescope. Read [docs](https://...)

## Ma setup structure

```lua
require('ma'.setup({
    vaults = {
        -- If nil or {}, it uses the current working directory as the root. By default the "active" vault is the first.
    },
    respect_gitignore = true,
    autochdir = "lcd",
    depth = nil,
    delete_to_trash = true,
    picker_actions = {
        { "c", "create" },
        { "r", "rename" },
        { "d", "delete" },
    },
    date_format_frontmatter = "%Y %b %d - %H:%M:%S",
    telescope = {},
    columns = { "git", "icons" },
    sort = { by = "name", order = "asc" },
    daily_notes = {
        date_format = nil, -- default "%Y.%b-%d"
        locale = nil, -- default current locale
    }
})
```

## License

This package is licensed under the Apache License. See [LICENSE](/LICENSE) for more information.
