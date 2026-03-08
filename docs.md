# Ma.nvim Docs

Ma.nvim lets structure emerge from filenames rather than directories.
Structure is relational rather than physical: folders are optional; meaning emerges from naming.

## Dependencies

- Required: `nvim-lua/plenary.nvim`
- Required for `:Ma` navigator and `:Ma vault`: `nvim-telescope/telescope.nvim`
- Optional: `nvim-tree/nvim-web-devicons` for filetype-aware file icons in the `icons` column. If the dependency is missing, Ma falls back to built-in icons (`` for folders, `󰈙` for files).

## Commands

### Navigation

Open the Telescope navigator for the active root.

**Example**
```vim
:Ma
```

**Use when:**
You want to browse notes as a dot-based tree and run picker actions.

### Vault

Pick and switch the active vault.

`:Ma vault` opens the vault picker.
`:Ma vault <name>` switches directly to an existing configured vault by name.

When a vault is selected, Ma sets it as active and reopens navigation in that vault.
The *active root* is the currently selected vault path, or Neovim’s current working directory if no valid vault is configured.

**Example**
```vim
:Ma vault
:Ma vault work
```

**Use when:**
You keep separate note collections (personal, work, research).

### Create note

Create or open a note from the command line.

**Behavior**
If the note exists, Ma opens it.
If it does not exist, Ma prompts for file name, title, and optional description, writes frontmatter, then opens it.

Name handling rules:
- You do not need to specify the `.md` extension. It is added automatically.
- Existing `.md` or `.markdown` suffixes are normalized and not duplicated.
- `/` is normalized to `.`
- Spaces are normalized to `-`

The final segment of the name always creates a file.
Ma does not create standalone “folders” — hierarchy exists only conceptually through dot-separated segments.

**Example**
```vim
:Ma create
```

**Use when:**
You want a quick create/open flow outside the Telescope picker.

### Daily note

Create or open the daily note.

Builds `daily.<formatted-date>.md` using `daily_notes` options. Disabled if `daily_notes = false`.

**Example**
```vim
:Ma daily
```

**Use when:**
You keep daily journal/log notes.

### Rename note

Rename the current managed note. Works only for markdown files under the active root.

**Example**
```vim
:Ma rename
```

**Use when:**
You want to rename the current note without opening the picker.

**Segment-aware renaming**
If you rename a note that represents a hierarchical segment, Ma updates all notes sharing that segment prefix.

Example:

Renaming `architecture.foster.apple-piazza-liberty`
to `architecture.norman-foster.apple-piazza-liberty`

will also rename notes such as:

- `architecture.foster.30-st-mary-axe`
- `architecture.foster.millennium-bridge`

to:

- `architecture.norman-foster.30-st-mary-axe`
- `architecture.norman-foster.millennium-bridge`

### Delete note(s)

Delete the current managed note with confirmation.
In the navigator picker, multi-select deletion is supported via Telescope multi-select. `:Ma delete` deletes only the current note.
Uses trash-first or hard-delete mode (see [`delete_to_trash`](#deletetotrash)).

**Example**
```vim
:Ma delete
```

**Use when:**
You want a safe delete flow from the current buffer.

### Link

Create a markdown link from the current visual selection.
Prompts for target note, opens/creates it, and replaces selection with `[label](target.md)`.

**Example**
```vim
:Ma link
```

**Important**
Run this from visual mode inside a managed markdown note.

**Use when:**
You are writing and want fast "create-and-link" behavior.

## Setup Template

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

  telescope = {
    prompt_prefix = " ",
    selection_caret = "| ",
    initial_mode = "insert", -- "insert" or "normal"
    layout_config = {
      width = 0.9,
      height = 0.9,
      preview_width = 0.6,
    },
  },

  columns = { "git", "icons" },
  sort = { by = "name", order = "asc" },

  daily_notes = {
    date_format = nil,
    locale = nil,
  },
})
```

## Reference

### `vaults`

List of vault roots Ma can use as note workspaces.

**Type**
`{ { name?: string, path: string } } | nil`

**Default**
`{}` (normalized to `nil` if empty/invalid)

**Behavior**
- Non-existing paths are ignored.
- Duplicate paths are deduplicated.
- Missing/empty `name` falls back to folder basename.
- First valid vault becomes active by default.

**Example**
```lua
vaults = {
  { name = "Personal", path = "~/notes/personal" },
  { name = "Work", path = "~/notes/work" },
}
```

**Important**
If no valid vault exists, Ma uses Neovim's current working directory.

**Use when:**
You want explicit, switchable note roots.

### `respect_gitignore`

Control whether scans exclude files ignored by `.gitignore`.

**Type**
`boolean`

**Default**
`true`

**Behavior**
Passed to `plenary.scandir.scan_dir(..., { respect_gitignore = ... })`.

**Example**
```lua
respect_gitignore = false
```

**Use when:**
Set to `false` only if you intentionally want ignored markdown files included.

### `autochdir`

Control whether Ma changes Neovim working directory to the active root before major actions.

**Type**
`false | "lcd" | "tcd" | "cd"`

**Default**
`"lcd"`

**Behavior**
- `false`: no directory change
- `"lcd"`: window-local cwd
- `"tcd"`: tab-local cwd
- `"cd"`: global cwd

**Example**
```lua
autochdir = "tcd"
```

**Important**
Applied when navigating, linking, creating, and opening daily notes.

**Use when:**
You want Ma's root and your relative-path tools to stay aligned.

### `depth`

Maximum directory recursion depth during note scanning.

**Type**
`integer | nil`

**Default**
`nil`

**Behavior**
- `nil`: unlimited recursion
- integer: scan only up to that depth

**Example**
```lua
depth = 3
```

**Use when:**
Your vault is large and you want faster scans.

### `delete_to_trash`

Choose trash-first deletion or direct deletion.

**Type**
`boolean`

**Default**
`true`

**Behavior**
When true, Ma tries OS trash tools first (`osascript` on macOS, `gio`, `trash-put`, `kioclient5`) and falls back to file removal.

**Example**
```lua
delete_to_trash = true
```

**Important**
Even with trash mode, fallback behavior can permanently delete files if no trash backend is available.

**Use when:**
You want safer delete operations.

### `picker_actions`

Keybindings available inside the navigator picker.

**Type**
`{ { key: string, action: "create"|"rename"|"delete" } } | false`

**Default**
```lua
{
  { "c", "create" },
  { "r", "rename" },
  { "d", "delete" },
}
```

**Behavior**
- `false` disables picker actions.
- List order is preserved.
- Legacy map forms are still accepted.

**Example**
```lua
picker_actions = {
  { "n", "create" },
  { "x", "delete" },
}
```

**Use when:**
You want custom action keys in Telescope.

### `date_format_frontmatter`

Date format for `created` and `updated` frontmatter fields.

**Type**
`string`

**Default**
`"%Y %b %d - %H:%M:%S"`

**Behavior**
Used for new note frontmatter and `updated` refresh on write.

**Example**
```lua
date_format_frontmatter = "%Y-%m-%d %H:%M"

```
**Important**
Ma updates `updated:` only if frontmatter exists at top of file and already contains an `updated` key.

**Use when:**
You need a specific timestamp style across notes.

### `telescope`

Override Telescope picker options specifically for Ma.

**Type**
`table`

**Default**
`{}`

**Behavior**
All keys provided in this table are forwarded to the underlying Telescope picker configuration used by Ma.

This allows you to customize layout, UI behavior, and other Telescope-specific options without affecting global Telescope setup.

Refer to the official [Telescope documentation](https://github.com/nvim-telescope/telescope.nvim/blob/master/README.md) for supported options.


**Example**
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
    }
}
```

**Use when:**
You want Ma pickers to match your Telescope UX.

### `columns`

Choose which navigator columns are shown and in what order.

**Type**
`table`

**Default**
```lua
{ "git", "icons" }
```

**Behavior**
- Supported column names: `"git"`, `"icons"`.
- Order in the array controls display order.
- If `git` column is not active, Ma skips Git status computation.

Use this when you want simpler or more informative picker rows.

#### Git

Nested key inside `columns` used to override Git status symbols for the `git` column.

**Type**
`table`

**Default**
`nil` (unset)

**Behavior**
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

Providing `git = {...}` auto-enables the `git` column if missing.

**Example**
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
If you want a custom Git visual language, be aware that when you override symbols, any statuses you do not explicitly set may render as blank.

#### Icons

Nested key inside `columns` used to customize folder/file icons in the `icons` column.

**Type**
`{ folder?: string, file?: string }`

**Behavior**
- `icons = {...}` auto-enables the icons column if missing.
- Icons are taken from `nvim-web-devicons` when the dependency is available.
- Icons resolution order if dependency is missing:
  - custom value from `folder` or `file` when non-empty string
  - folder fallback: ``
  - file fallback: `󰈙`

Setup summary:
```lua
-- default
columns = { "git", "icons" }

-- custom fixed icons (dependency optional)
columns = {
  "git",
  icons = {
      folder = "F ",
      file = "md",
  }
}
```

Use this when you want explicit icon behavior with or without `nvim-web-devicons`.

### `sort`

Sort strategy for entries in each picker level.

**Type**
`{ by?: "name"|"update"|"creation", order?: "asc"|"desc" }`

**Default**
```lua
{ by = "name", order = "asc" }
```

**Behavior**
- `name`: case-insensitive by segment text
- `update`: by file mtime
- `creation`: by birthtime/ctime fallback
- Ties fall back to full note path for deterministic order

**Example**
```lua
sort = { by = "update", order = "desc" }
```

**Use when:**
You want recency-first or chronology-first navigation.

### `daily_notes`

Enable/disable daily note generation and control date formatting.

**Type**
`table | false`

**Default**
```lua
{ date_format = nil, locale = nil }
```

**Behavior**
- `false`: disables `:Ma daily`
- table: creates/opens `daily.<date>.md`

**Example**
```lua
daily_notes = {
  date_format = "%Y.%m.%d",
  locale = "en_US.UTF-8",
}
```

Example output: `daily.2026.Mar-03.md`

**Use when:**
You maintain date-based daily notes.

### `daily_notes.date_format`

Date token pattern used in daily note filename and title.

**Type**
`string | nil`

**Default**
`"%Y.%b-%d"` (when nil)

**Behavior**
Uses Lua `os.date`/`strftime`-style tokens.

**Example**
```lua
daily_notes = { date_format = "%Y-%m-%d" }
```

**Important**
Since this value becomes part of the note name, separators (`.` and `-`) affect hierarchy and readability.

**Use when:**
You want ISO-like names or locale-friendly names.

### `daily_notes.locale`

Locale used while formatting daily note dates.

**Type**
`string | nil`

**Default**
`nil` (current process locale)

**Behavior**
Temporarily applies `os.setlocale(locale, "time")`, formats the date, then restores previous locale.

**Example**
```lua
daily_notes = { locale = "it_IT.UTF-8" }
```

**Use when:**
You want month/day names in a specific language.

## Picker Behavior

- `Enter`: open folder/file
- `Backspace` (normal mode): go up when prompt is empty
- `-` (normal mode): force go up
- `Ctrl-h` (insert mode): force go up
- Action keys come from `picker_actions`
- Multi-select + delete is supported in picker delete action

## Frontmatter

When creating a new note via `:Ma create` or `:Ma daily`,
Ma generates YAML frontmatter with the following structure:

```yaml
---
id: <23-char random id>
title: <title>
desc: <desc>
updated: <formatted timestamp>
created: <formatted timestamp>
---
```

**Behavior**
- `created` and `updated` use [`date_format_frontmatter`](#date_format_frontmatter)
- `updated` is refreshed on `BufWritePre` for managed markdown files under the active root.
- `updated` is only modified if frontmatter exists and contains an `updated:` field.
- Notes without frontmatter are left untouched.
- The id field is generated automatically and is not currently used for indexing or linking.
