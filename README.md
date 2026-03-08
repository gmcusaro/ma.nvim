# Ma.nvim

![NVIM](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)

<div align="center">
<img width="150" height="150" alt="Image" src="https://github.com/user-attachments/assets/979f03be-a134-47d4-a98e-272656dfa3ef" />
</div>
<br>

A minimal knowledge layer for Markdown in [Neovim](https://neovim.io).

Ma.nvim lets structure emerge from filenames rather than directories. Notes live in a flat filesystem, while hierarchy is inferred through dot-separated segments and hyphenated words.

Inspired by [Dendron](https://www.dendron.so) and [Obsidian](https://obsidian.md), Ma provides vault-scoped navigation and safe file operations without imposing folder-based structure.

## Why Ma?

**Ma** (間) is a Japanese concept often translated as *interval* or *space between*.

It does not mean emptiness as absence.
It refers to meaningful space: the gap that makes relationships possible.

In Ma.nvim, structure is not imposed through folders. It emerges in the intervals:

- Dots define hierarchy.
- Hyphens define words.
- Meaning lives in the space between segments.

Ma also implies time: the pause between actions, the space we take to write, reflect, and connect ideas in plain text.

### Example file name

*architecture.norman-foster.apple-piazza-liberty.md*

Ma interprets this as a hierarchy:

📁 architecture<br />
└ 📁 norman-foster<br />
  └ 📄 apple-piazza-liberty


![ma navigation preview](ma-navigation-preview.png)

## Getting Started

### Requirements

- [Neovim >= 0.11.0](https://github.com/neovim/neovim/releases/tag/v0.11.0)

### Dependencies

**Required:**
- [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nvim-telescope/telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for navigator and vault picker

**Optional:**
- [nvim-tree/nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for filetype-aware icons in the `icons` column. If missing, Ma falls back to built-in icons (`` folders, `󰈙` files).
- [telescope-fzf-native.nvim](https://github.com/nvim-telescope/telescope-fzf-native.nvim) for faster picker matching.
- [Marksman (Markdown LSP)](https://github.com/artempyanykh/marksman) for `gd` on links, semantic link resolution, and document symbols.

### Installation

Pinning to the latest release tag is recommended.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "gmcusaro/ma.nvim",
  version = "*",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    { "nvim-tree/nvim-web-devicons", opts = {} },
  },
  opts = {
    vaults = {
      { name = "My Brain", path = "~/notes" },
    },
  },
}
```

## Default Setup

```lua
require("ma").setup({
  vaults = {
    { name = "My Brain", path = "~/notes" },
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
    date_format = nil,
    locale = nil,
  }
})
```

## Commands

### `:Ma`

Open the Telescope navigator for the active root. Use it to browse notes as a dot-based tree and run picker actions.

### `:Ma vault` / `:Ma vault <name>`

Pick and switch the active vault.

- `:Ma vault` opens the vault picker and switches the active vault.
- `:Ma vault <name>` switches directly to an existing configured vault by name.

When a vault is selected, Ma sets it as active and reopens navigation in that vault.
The *active root* is the currently selected vault path, or Neovim's current working directory if no valid vault is configured.

Use when:
- You keep separate note collections (personal, work, research).

### `:Ma create`

Create or open a note from the command line.

Behavior:
- If the note exists, Ma opens it.
- If it does not exist, Ma prompts for file name, title, and optional description, writes frontmatter, then opens it.

Name handling:
- `.md` is added automatically if omitted.
- Existing `.md` or `.markdown` suffixes are normalized and not duplicated.
- `/` is normalized to `.`.
- Spaces are normalized to `-`.

The final segment of the name always creates a file.
Ma does not create standalone "folders"; hierarchy exists conceptually through dot-separated segments.

Use when:
- You want a quick create/open flow outside the Telescope picker.

### `:Ma daily`

Create or open the daily note. Use it to keep daily journal/log notes.

Builds `daily.<formatted-date>.md` using [`daily_notes`](#daily_notes) options.

### `:Ma rename`

Rename the current managed note. Works only for markdown files under the active root.
This command renames only the current note file.

Use when:
- You want to rename the current note without opening the picker.

Picker folder rename (multi-file):
- In the navigator picker, renaming a folder segment updates all notes sharing that segment prefix.

Example:
- Renaming a folder segment
    `architecture.foster.apple-piazza-liberty`
  into
  `architecture.norman-foster.apple-piazza-liberty`
- Also renames notes such as
    `architecture.foster.30-st-mary-axe`
    `architecture.foster.millennium-bridge`
  into
    `architecture.norman-foster.30-st-mary-axe`
    `architecture.norman-foster.millennium-bridge`

### `:Ma delete`

Delete the current note with confirmation.
Works only for managed markdown notes under the active root.
In the navigator picker, multi-select deletion is supported via Telescope multi-select.
Uses trash-first or hard-delete mode (see [`delete_to_trash`](#delete_to_trash)).

### `:Ma link`

Create a markdown link from the current visual selection.
Prompts for target note, opens/creates it, and replaces selection with `[label](target.md)`.
The target note name is normalized and lowercased.

Important:
- Run this from visual mode inside a managed markdown note.

Use when:
- You are writing and want fast create-and-link behavior.

## Picker Behavior

- `Enter`: open folder/file.
- `Backspace` (normal mode): go up when prompt is empty.
- `-` (normal mode): force go up.
- `Ctrl-h` (insert mode): force go up.
- Action keys come from [`picker_actions`](#picker_actions) in normal mode.
- Multi-select + delete is supported in the picker delete action.

## Configuration Reference

### `vaults`

List of vault roots Ma can use as note workspaces.

Type:
- `{ { name?: string, path: string } } | nil`

Default:
- `{}`

Behavior:
- Invalid/non-existing paths are ignored
- Duplicate paths are deduplicated.
- Missing/empty `name` falls back to folder basename.
- First valid vault becomes active by default.
- If no valid vault exists, Ma.nvim uses current working directory.

Example:

```lua
vaults = {
  { name = "Personal", path = "~/notes/personal" },
  { name = "Work", path = "~/notes/work" },
}
```

Important:
- If no valid vault exists, Ma uses Neovim's current working directory.

Use when:
- You want explicit, switchable note roots.

### `respect_gitignore`

Control whether scans exclude files ignored by `.gitignore`.

Type:
- `boolean`

Default:
- `true`

Example:

```lua
respect_gitignore = false
```

Use when:
- Set to `false` only if you intentionally want ignored markdown files included.

### `autochdir`

Control whether Ma changes Neovim working directory to the active root before major actions.

Type:
- `false | "lcd" | "tcd" | "cd"`

Default:
- `"lcd"`

Behavior:
- `false`: no directory change.
- `"lcd"`: window-local cwd.
- `"tcd"`: tab-local cwd.
- `"cd"`: global cwd.

Example:

```lua
autochdir = "tcd"
```

Important:
- Applied when navigating, linking, creating, and opening daily notes.

Use when:
- You want Ma's root and your relative-path tools to stay aligned.

### `depth`

Maximum directory recursion depth during note scanning.

Type:
- `integer | nil`

Default:
- `nil`

Behavior:
- `nil`: unlimited recursion.
- integer: scan only up to that depth.

Example:

```lua
depth = 3
```

Use when:
- Your vault is large and you want faster scans.

### `delete_to_trash`

Choose trash-first deletion or direct deletion.

Type:
- `boolean`

Default:
- `true`

Behavior:
- When true, Ma tries OS trash tools first (`osascript` on macOS, `gio`, `trash-put`, `kioclient5`) and falls back to file removal.

Example:

```lua
delete_to_trash = true
```

Important:
- Even with trash mode, fallback behavior can permanently delete files if no trash backend is available.

Use when:
- You want safer delete operations.

### `picker_actions`

Keybindings available inside the navigator picker.

Type:
- `{ { string, "create"|"rename"|"delete" } } | { [string]: "create"|"rename"|"delete" } | false`

Default:

```lua
{
  { "c", "create" },
  { "r", "rename" },
  { "d", "delete" },
}
```

Behavior:
- `false` disables picker actions.
- List order is preserved.
- Legacy map forms are still accepted.

Example:

```lua
picker_actions = {
  { "n", "create" },
  { "x", "delete" },
}
```

Use when:
- You want custom action keys in Telescope.

### `date_format_frontmatter`

Date format for `created` and `updated` frontmatter fields.

Type:
- `string`

Default:
- `"%Y %b %d - %H:%M:%S"`

Behavior:
  Used for `created`/`updated` timestamps in frontmatter.
  `updated` is refreshed only if:
  - frontmatter exists at top of file
  - frontmatter already has an `updated:` key

Example:

```lua
date_format_frontmatter = "%Y-%m-%d %H:%M"
```

Important:
- Ma updates `updated:` only if frontmatter exists at top of file and already contains an `updated` key.

Use when:
- You need a specific timestamp style across notes.

### `telescope`

Override Telescope picker options specifically for Ma.

Type:
- `table`

Default:
- `{}`

Behavior:
- Supported keys are: `prompt_prefix`, `selection_caret`, `initial_mode`, and `layout_config`.
- `initial_mode` accepts only `"insert"` or `"normal"`.
- Other Telescope keys are ignored by Ma.

Supported options are documented in the [Telescope README](https://github.com/nvim-telescope/telescope.nvim/blob/master/README.md).

Example:

```lua
telescope = {
  prompt_prefix = " ",
  selection_caret = "| ",
  initial_mode = "normal",
  layout_config = {
    prompt_position = "top",
    width = 0.9,
    height = 0.9,
    preview_width = 0.6,
    mirror = false,
    preview_cutoff = 120,
  },
}
```

Use when:
- You want Ma pickers to match your Telescope UX.

### `columns`

Choose which navigator columns are shown and in what order.

Type:
- `table`

Default:

```lua
{ "git", "icons" }
```

Behavior:
- Supported column names: `"git"`, `"icons"`.
- Order in the array controls display order.
- If `git` column is not active, Ma skips Git status computation.

Use when:
- You want simpler or more informative picker rows.

#### `columns.git`

Nested key inside `columns` used to override Git status symbols for the `git` column.

Type:
- `table`

Default:
- `nil` (unset)

Built-in symbols (used when `git` column is enabled):

```lua
{
  clean = "  ",
  modified = "M ",
  added = "A ",
  deleted = "D ",
  renamed = "R ",
  copied = "C ",
  untracked = "? ",
  ignored = "! ",
  conflicted = "U ",
  unknown = "~ ",
}
```

Behavior:
- Providing `git = {...}` auto-enables the `git` column if missing.
- If you override symbols, statuses not explicitly set may render as blank.

Example:

```lua
columns = {
  git = {
    modified = "✱ ",
    untracked = "… ",
    conflicted = "‼ ",
  },
  "icons",
}
```

#### `columns.icons`

Nested key inside `columns` used to customize folder/file icons in the `icons` column.

Type:
- `{ folder?: string, file?: string }`

Behavior:
- `icons = {...}` auto-enables the icons column if missing.
- A non-empty `icons.folder` or `icons.file` value is used directly.
- Without a custom value:
  - folders use fallback ``
  - files use `nvim-web-devicons` when available, else fallback `󰈙`

Examples:

```lua
-- default
columns = { "git", "icons" }

-- custom fixed icons (dependency optional)
columns = {
  "git",
  icons = {
    folder = "F ",
    file = "md",
  },
}
```

Use when:
- You want explicit icon behavior with or without `nvim-web-devicons`.

### `sort`

Sort strategy for entries in each picker level.

Type:
- `{ by?: "name"|"update"|"creation", order?: "asc"|"desc" }`

Default:

```lua
{ by = "name", order = "asc" }
```

Behavior:
- `name`: case-insensitive by segment text.
- `update`: by file mtime.
- `creation`: by birthtime/ctime fallback.
- Ties fall back to full note path for deterministic order.

Example:

```lua
sort = { by = "update", order = "desc" }
```

Use when:
- You want recency-first or chronology-first navigation.

### `daily_notes`

Enable/disable daily note generation and control date formatting.

Type:
- `table | false`

Default:

```lua
{ date_format = nil, locale = nil }
```

Behavior:
- `false`: disables `:Ma daily`.
- table: creates/opens `daily.<date>.md`.

Example:

```lua
daily_notes = {
  date_format = "%Y.%m.%d",
  locale = "en_US.UTF-8",
}
```

Example output: `daily.2026.Mar-03.md`

Use when:
- You maintain date-based daily notes.

### `daily_notes.date_format`

Date token pattern used in daily note filename and title.

Type:
- `string | nil`

Default:
- `"%Y.%b-%d"` (when nil)

Behavior:
- Uses Lua `os.date`/`strftime`-style tokens.

Example:

```lua
daily_notes = { date_format = "%Y-%m-%d" }
```

Important:
- Since this value becomes part of the note name, separators (`.` and `-`) affect hierarchy and readability.

Use when:
- You want ISO-like names or locale-friendly names.

### `daily_notes.locale`

Locale used while formatting daily note dates.

Type:
- `string | nil`

Default:
- `nil` (current process locale)

Behavior:
- Temporarily applies `os.setlocale(locale, "time")`, formats the date, then restores previous locale.

Example:

```lua
daily_notes = { locale = "it_IT.UTF-8" }
```

Use when:
- You want month/day names in a specific language.

## Frontmatter

When creating a new note via `:Ma create` or `:Ma daily`,
Ma generates YAML frontmatter with this structure:

```yaml
---
id: <23-char random id>
title: <title>
desc: <desc>
updated: <formatted timestamp>
created: <formatted timestamp>
---
```

Behavior:
- Frontmatter is written only when a note file is newly created; opening an existing note does not insert or rewrite frontmatter.
- `created` and `updated` use [`date_format_frontmatter`](#date_format_frontmatter).
- `updated` is refreshed on `BufWritePre` for managed markdown files under the active root.
- `updated` is only modified if frontmatter exists and contains an `updated:` field.
- Notes without frontmatter are left untouched.
- `id` is generated automatically and is not currently used for indexing or linking.

## Contributing

All contributions are welcome! Just open a pull request.
