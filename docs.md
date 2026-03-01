# Ma.nvim - Docs

## Options

### `vaults` — Configuration and Usage

Ma organizes your notes into one or more vaults — isolated directories that act as individual note collections.

**What is a Vault?**

Vaults define the root directories managed by ma.nvim.
A vault is a root folder containi Markdown notes. Each vault is isolated and operates independently from others.

#### How to configure Vaults

Define vaults inside your plugin setup. Ma does not create vault folders — they must already exist.
Trailing slashes are normalized away.

**Every vault must define:**

`name` — The display name shown in pickers and prompts

- Used only for display purposes (vault picker, titles).
- If omitted or empty, the normalized path is used instead.
- Does not affect filesystem behavior.

`path` — The absolute directory path to the vault root

- Must point to a directory.
- `~` is expanded automatically.
- Trailing slashes are normalized.
- Internally converted to an absolute normalized path.

If the directory does not exist, behavior depends on your usage (Hematite does not automatically create vault roots).

Example

```lua
vaults = {
    {
        name = "Personal",
        path = "~/personal/notes",
    }
    {
        name = "Work",
        path = "~/work/notes",
    },
}
```

#### Work with multiple vaults

The first vault in your list becomes the active vault by default. To switch valuts using: `:Ma vault`. Switching vaults changes the logical root for all operations.

Selecting a vault:
Navigation only shows notes inside the active vault.
Sets it as the active vault
May change Neovim’s working directory depending on `autochdir`

#### Single-Vault Mode (Implicit)

If you prefer project-based behavior:

```lua
require("hematite").setup({
    vaults = nil,
})
```

Use the current working directory as the root
Disable vault selection
Operate as a single-root manager

#### Why You Should Initialize Git in Each Vault

If you use Marksman for Markdown navigation, it is strongly recommended that each vault be its own Git repository.

Marksman operates within a single workspace root, determined when it attaches to a buffer. It analyzes and resolves links only within that workspace. If the workspace root does not align with the active vault, link resolution and cross-note navigation may become unreliable.

This situation can occur when:
- Neovim is started outside the vault directory
- The vault is nested inside another project
- Marksman attaches before the vault root is clearly established

When the vault is not recognized as the workspace boundary, you may experience:
- Markdown links not resolving
- `gd` on links failing
- Cross-note navigation behaving inconsistently

Hematite is designed to reduce friction in note-taking. You should not need to manually `cd` into your notes directory every time you start Neovim.The [`autochdir` option](#directory-management-autochdir) improves this experience by automatically aligning Neovim’s working directory with the active vault.

### Respect Gitignore

Controls whether note scanning respects .gitignore rules when building the navigation tree.

`respect_gitignore`

**Type**

`boolean`

**Default**

`true`

**Behavior**

- `true` → Files ignored by `.gitignore` are excluded from navigation.
- `false` → All Markdown files are scanned, ignoring `.gitignore`.

**Notes**

- This affects note scanning only.
- It does not change manual `:edit` behavior.
- If the vault is not a Git repository, this option has no effect.

Use false only if you intentionally want ignored files to appear in the tree.

### `autochdir` - Directory Management

Hematite can optionally change Neovim’s working directory to match the active vault.
This is controlled by:

```lua
autochdir = false | "lcd" | "tcd" | "cd"
```

Neovim supports three levels of working directory:

| Command | Scope        | Affects                   | Overrides     |
| ------- | ------------ | ------------------------- | ------------- |
| `:cd`   | Global       | Entire Neovim instance    | —             |
| `:tcd`  | Tab-local    | Current tab (all windows) | `:cd`         |
| `:lcd`  | Window-local | Current window only       | `:tcd`, `:cd` |

Precedence (most specific wins) `:lcd  >  :tcd  >  :cd`

#### `autochdir = false`

**Behavior**

Hematite does not modify Neovim’s working directory.

- `vim.fn.getcwd()` remains unchanged.
- No `:cd`, `:tcd`, or `:lcd` is executed.
- The editor keeps whatever directory it started with.

**Important**

Hematite still internally uses the active vault path for:
- Scanning notes
- Creating notes
- Renaming/deleting
- Link creation
- Frontmatter updates

However:
- Relative `:edit` commands use Neovim’s current directory.
- `gf` resolves paths from Neovim’s current directory.
- LSP root detection is unaffected by vault switching.
- Tools relying on getcwd() may behave differently from the vault root.

**Use when:**
- You do not want the editor’s `cwd` to change.
- You manage LSP roots explicitly.
- You prefer vault isolation without affecting other plugins.

#### `autochdir = cd`

Equivalent to running: `:cd <vault_root>`

Scope

Entire Neovim session.

- All tabs
- All windows
- All buffers

Effects
- `vim.fn.getcwd()` becomes the vault root globally.
- Relative paths resolve from the vault.
- LSP servers that derive root from `cwd` may use the vault.
- Other projects opened in other tabs also inherit this root.

Use when
You work on one vault/project per Neovim session.
You want maximum consistency across all windows and tabs.

#### `autochdir = "tcd"`

Equivalent to: `:tcd <vault_root>`

Scope:
Current tab only.
All windows inside the current tab.
Other tabs remain unchanged.

Effects:
- `getcwd()` differs per tab.
- Each tab can represent a separate vault/project.
- Overrides global `:cd`.
- Can still be overridden per-window via `:lcd`.

Use when:
- Each tab represents a separate vault.
- You want project isolation per tab.
- You frequently work across multiple vaults.

#### `autochdir = "lcd"`

Equivalent to: `:lcd <vault_root>`

Scope:
- Current window only.
- Does not affect other windows in the same tab.
- Overrides both `:tcd` and `:cd`.

Effects:
- Each split can have a different working directory.
- Most granular control.
- Relative paths and tools operate per-window.

Use when:
- You intentionally mix directories in splits.
- You want fine-grained control.
- You understand Vim’s local directory semantics.

**LSP Considerations (Marksman)**

Hematite does not require an LSP server to function.

However, semantic Markdown navigation (e.g. jumping from
`[text](note.md)` to the target note using `gd` or `<CR>`)
depends on an LSP that understands Markdown links.

### Depth

Controls how deep the filesystem scan goes when building the note tree.

**Type**

`integer | nil`

**Default**

`nil`

**Behavior**

- `nil` → Unlimited recursion
  Scans the entire vault directory tree.

- `integer` → Maximum recursion depth
  Limits how many directory levels are scanned.

**Example**

```lua
depth = 3
```

This scans:

Vault root

1st level subdirectories
2nd level
3rd level
Then stops.

**Important**

- Depth applies to filesystem directories.
- It does not limit dot-based logical hierarchy (project.idea.subidea).
- It only affects scanning performance and tree size.

**Use when:**

- Your vault is extremely large.
- You want to restrict scanning for performance reasons.

### Delete to trash

`delete_to_trash = false`

### Picker actions

```lua
picker_actions = {
    { "c", "create" },
    { "r", "rename" },
    { "d", "delete" },
}
```

### Format Date Frontmatter

Per default: `date_format_frontmatter = "%Y %b %d - %H:%M:%S"`

https://docs.osmos.io/data-transformations/formulas/date-and-time-formulas/date-format-specifiers

### Telescope



### Columns

`columns`

**Type**

`table`

**Default**

```lua
columns = { "git", "icon" }
```

**Description**

Controls which columns are displayed in the Telescope navigator and in what order.
Supported Columns

"git" → Shows Git status indicator
"icon" → Shows file/folder icon

Columns are rendered left to right in the order defined.

Notes

If "git" is not enabled, Git status is not computed (faster).
If "icon" is enabled but `nvim-web-devicons` is missing, a default icon is used.

**Custom Git Symbols**

You can override Git symbols by providing a git table.

```lua
columns = {
  git = {
    modified = "✱ ",
  },
  "icon",
}
```

When a git table is provided:

- The "git" column is automatically enabled.
- Custom symbols override defaults.
- Unspecified statuses fall back to empty (unless defined

**Default Git Status Labels**

Internally supported statuses:

- `clean`
- `modified`
- `added`
- `deleted`
- `renamed`
- `copied`
- `untracked`
- `ignored`
- `conflicted`
- `unknown`

Example with multiple overrides:

```lua
columns = {
  git = {
    modified  = "M ",
    added     = "A ",
    deleted   = "D ",
    untracked = "? ",
  },
  "icon",
}
```

### Sorting

L'ordinamento può essere seguito in base a:

Default value:
`{ by = "name", order = "asc" }`

```lua
sort =
-- { by = "update", order = "desc" },
    -- { by = "update", order = "asc" },
    -- { by = "creation", order = "asc" },
    -- { by = "creation", order = "desc" },
    -- { by = "name", order = "desc" },
```

### Telescope

```lua
telescope = {
    prompt_prefix = " ",
    selection_caret = "| ",
    initial_mode = "normal",
    layout_config = {
        prompt_position = "bottom",
        width = 0.9,
        height = 0.9,
        preview_width = 0.6,
        mirror = false,
        preview_cutoff = 120,
    },
},
```

### Daily Notes

`daily_notes`

**Type**

`table | false`

**Default**

```lua
daily_notes = {
  date_format = nil, -- default "%Y.%b-%d"
  locale = nil,      -- default current process locale
}
```

Description

Controls locale-sensitive formatting (month names, etc) used to create daily note.

#### `date_format`

**Type**

`string | nil`

**Default**

`%Y.%b-%d`

**Description**

Defines the filename date format.
Uses Lua `os.date()` format specifiers (`strftime`-style tokens). add link
L'uso di `.` e `-` influisce sulla gerarchia di come le note vengono visualizzate con Ma.

#### `locale`

**Type**

string | nil

**Default**

nil → current process locale

**Description**

Controls locale-sensitive formatting.

If set, ma.nvim:

Temporarily calls `os.setlocale(locale, "time")`
Formats the date with `os.date()`
Restores the previous locale

**Example:**

```lua
daily_notes = {
  locale = "it_IT.UTF-8",
}
```

Add link to locale values
