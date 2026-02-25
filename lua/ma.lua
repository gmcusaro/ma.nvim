local M = {}

--==============================================================
-- Deps (safe require)
--==============================================================
local function safe_require(mod)
    local ok, m = pcall(require, mod)
    return ok and m or nil
end

local scandir = safe_require("plenary.scandir")
local Path = safe_require("plenary.path")
local Job = safe_require("plenary.job")

--==============================================================
-- Config
--==============================================================
M._config = {
    vaults = { -- If nil or {}, it uses the current working directory as the root. By default the "active" vault is the first.
        {
            name = "Brain",
            path = "~/Brain/notes"
        },
        {
            name = "Test",
            path = "~/Desktop/Test/"
        }
    },
    respect_gitignore = true,
    autochdir = "lcd", -- Values: false | "lcd" | "tcd" | "cd"
    depth = nil,
    delete_to_trash = true,
    picker_actions = {
        { "c", "create" },
        { "r", "rename" },
        { "d", "delete" },
    },
    date_format_frontmatter = "%Y %b %d - %H:%M:%S",
    telescope_initial_mode = "normal",  -- or "insert"
    columns = { "git", "icon" }, -- can be: { git = { modified="✱ " }, "icon" }
    sort =
    -- { by = "update", order = "desc" },
    -- { by = "update", order = "asc" },
    -- { by = "creation", order = "asc" },
    -- { by = "creation", order = "desc" },
    { by = "name", order = "asc" },
    -- { by = "name", order = "desc" },
    daily_notes = {
        date_format = nil, -- optional, default "%Y.%b-%d"
        locale = nil, -- optional, default current locale
    }
}

--==============================================================
-- General small utils (used everywhere)
--==============================================================
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--==============================================================
-- Path / FS utils (PlenaryPath wrapper)
--==============================================================
local function normpath(p)
    if not p or p == "" then return nil end
    p = vim.fn.expand(p)
    if vim.fs and vim.fs.normalize then
        p = vim.fs.normalize(p)
    else
        p = p:gsub("\\", "/")
    end
    return (p:gsub("/+$", ""))
end

local function P(p)
    if not Path or not p or p == "" then return nil end
    if type(Path.new) == "function" then return Path:new(p) end
    return nil
end

local function exists(p)
    if not p or p == "" then return false end
    local uv = vim.uv or vim.loop
    local np = normpath(p)
    if not np then return false end
    return uv.fs_stat(np) ~= nil
end

local function mkdir_parent(p)
    local o = P(p)
    if not o or not o.parent then return false end
    local parent = o:parent()
    if parent and parent.mkdir then
        parent:mkdir({ parents = true })
        return true
    end
    return false
end

local function write_file_if_missing(p, contents)
    if not p or p == "" then return false end
    if exists(p) then return false end
    local o = P(p)
    if not o or not o.write then return false end
    mkdir_parent(p)
    o:write(contents, "w")
    return true
end

local function rm_file(p)
    local o = P(p)
    if not o or not o.rm or not o.exists then return false end
    if not o:exists() then return false end
    pcall(function() o:rm() end)
    return true
end

local function rename_file(from, to)
    local o = P(from)
    if not o or not o.rename then return false end
    mkdir_parent(to)
    o:rename({ new_name = to })
    return true
end

local function is_under(path, root)
  if not path or path == "" or not root or root == "" then return false end
  path = (normpath(path) or path:gsub("\\", "/"))
  root = ((normpath(root) or root:gsub("\\", "/")):gsub("/+$", ""))

  if path:sub(1, #root) ~= root then return false end
  local nextch = path:sub(#root + 1, #root + 1)
  return nextch == "" or nextch == "/"
end

--==============================================================
-- Vault utils (root selection + chdir)
--==============================================================
local function basename(p)
  p = (p or ""):gsub("\\", "/"):gsub("/+$", "")
  return p:match("([^/]+)$") or p
end

local function is_dir(p)
  local uv = vim.uv or vim.loop
  local st = p and uv and uv.fs_stat(p) or nil
  return st and st.type == "directory"
end

local function normalize_vaults(vault)
  if type(vault) ~= "table" or vim.tbl_isempty(vault) then return nil end

  local out, seen = {}, {}

  for _, v in ipairs(vault) do
    if type(v) == "table" and type(v.path) == "string" and v.path ~= "" then
      local p = normpath(v.path)

      if p and p ~= "" and is_dir(p) then
        if not seen[p] then
          seen[p] = true
          local name = (type(v.name) == "string" and v.name ~= "") and v.name or basename(p)
          out[#out + 1] = { name = name, path = p }
        end
      end
    end
  end

  return (#out > 0) and out or nil
end

local function active_root()
    local v = M._config._active_vault
    if v and v.path and v.path ~= "" then return v.path end
    return normpath(vim.fn.getcwd())
end

local function maybe_chdir_to_active_root()
    local mode = M._config.autochdir
    if not mode or mode == false then return end

    local root = active_root()
    if not root or root == "" then return end

    local esc = vim.fn.fnameescape(root)
    if mode == "lcd" then vim.cmd("lcd " .. esc)
    elseif mode == "tcd" then vim.cmd("tcd " .. esc)
    elseif mode == "cd" then vim.cmd("cd " .. esc)
    end
end

--==============================================================
-- FS metadata (uv/fs_stat) for sorting
--==============================================================
local function ms(t)
  if type(t) == "table" and type(t.sec) == "number" then
    return t.sec * 1000 + math.floor((t.nsec or 0) / 1e6)
  end
  return 0
end

local function file_times_ms(path)
  local uv = vim.uv or vim.loop
  local st = (path and uv) and uv.fs_stat(path) or nil
  if not st then return 0, 0 end

  local mtime = ms(st.mtime)

  local birth = ms(st.birthtime)
  local ctime = ms(st.ctime)
  local creation = birth ~= 0 and birth or (ctime ~= 0 and ctime or mtime)

  return creation, mtime
end

--==============================================================
-- Date formatting (shared)
--==============================================================
local function format_stamp(fmt, locale)
    fmt = (type(fmt) == "string" and fmt ~= "") and fmt or "%Y.%b-%d"

    if not locale or locale == "" then
        return os.date(fmt)
    end

    local old = os.setlocale(nil, "time")
    os.setlocale(locale, "time")
    local s = os.date(fmt)
    os.setlocale(old, "time")
    return s
end

--==============================================================
-- Note/frontmatter utils (ids, titles, file detection)
--==============================================================
-- Seed math.random once (do NOT reseed per id)
do
    local _uv = vim.uv or vim.loop
    local seed = (_uv and _uv.hrtime and _uv.hrtime() or os.time()) % 2147483647
    math.randomseed(seed)
    math.random(); math.random(); math.random()
end

local function nanoid_like(len)
    len = len or 23
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = {}
    for _ = 1, len do
        local idx = math.random(1, #alphabet)
        out[#out + 1] = alphabet:sub(idx, idx)
    end
    return table.concat(out)
end

local function title_from_note_name(note_full)
    local last = note_full:match("([^.]+)$") or note_full
    local s = (last or "")
    :gsub("[%-%_]+", " ")
    :gsub("%s+", " ")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
    if s == "" then return "Untitled" end
    return s:sub(1, 1):upper() .. s:sub(2)
end

local function frontmatter_text(note_full, title, desc)
    local t = (title and title ~= "") and title or title_from_note_name(note_full)
    local d = desc or ""
    local id = nanoid_like(23)

    local stamp = format_stamp(M._config.date_format_frontmatter, nil)

    return table.concat({
        "---",
        ("id: %s"):format(id),
        ("title: %s"):format(t),
        ("desc: %s"):format(d),
        ("updated: %s"):format(stamp),
        ("created: %s"):format(stamp),
        "---",
        "",
    }, "\n")
end

local function is_note_file(path)
    local ext = path:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "md" or ext == "markdown"
end

--==============================================================
-- Trash delete (best effort)
--==============================================================
local uv = vim.uv or vim.loop
local SYSNAME = (uv and uv.os_uname and uv.os_uname().sysname) or ""

local function is_exe(bin)
    return vim.fn.executable(bin) == 1
end

local function try_job(cmd, args)
    if not Job or not is_exe(cmd) then return false end
    local ok, j = pcall(function()
        return Job:new({ command = cmd, args = args })
    end)
    if not ok or not j then return false end
    local ok2 = pcall(function() j:sync() end)
    if not ok2 then return false end
    return j.code == 0
end

local function trash_file(p)
    if not p or p == "" or not exists(p) then return false end

    if SYSNAME == "Darwin" then
        local esc = (p:gsub("\\", "\\\\"):gsub('"', '\\"'))
        local script = 'tell application "Finder" to delete POSIX file "' .. esc .. '"'
        if try_job("osascript", { "-e", script }) then return true end
    end

    if try_job("gio", { "trash", p }) then return true end
    if try_job("trash-put", { p }) then return true end
    if try_job("kioclient5", { "move", p, "trash:/" }) then return true end

    return rm_file(p)
end

--==============================================================
-- Git status map + aggregation
--==============================================================
local DEFAULT_GIT_SYMBOLS = {
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

local function git_label_from_xy(xy)
    if not xy or xy == "" then return "clean" end
    if xy == "??" then return "untracked" end
    if xy == "!!" then return "ignored" end

    local conflicts = { UU = true, AA = true, DD = true, AU = true, UA = true, DU = true, UD = true }
    if conflicts[xy] then return "conflicted" end

    local function one(ch)
        if ch == "M" then return "modified" end
        if ch == "A" then return "added" end
        if ch == "D" then return "deleted" end
        if ch == "R" then return "renamed" end
        if ch == "C" then return "copied" end
        if ch == "U" then return "conflicted" end
        if ch == "?" then return "untracked" end
        if ch == "!" then return "ignored" end
        if ch == " " then return nil end
        return "unknown"
    end

    return one(xy:sub(1, 1)) or one(xy:sub(2, 2)) or "clean"
end

local GIT_PRIORITY = {
    conflicted = 900,
    deleted = 800,
    renamed = 700,
    copied = 650,
    added = 600,
    modified = 500,
    untracked = 400,
    ignored = 100,
    unknown = 50,
    clean = 0,
}

local function git_worst(a, b)
    a = a or "clean"
    b = b or "clean"
    return (GIT_PRIORITY[a] or 0) >= (GIT_PRIORITY[b] or 0) and a or b
end

local function build_git_status_map(cwd)
    if not Job or not cwd or cwd == "" then return nil end
    cwd = normpath(cwd)
    if not cwd then return nil end

    local ok_top, top = pcall(function()
        return Job:new({ command = "git", args = { "-C", cwd, "rev-parse", "--show-toplevel" } }):sync()
    end)
    if not ok_top or not top or not top[1] or top[1] == "" then return nil end
    local toplevel = normpath(top[1])
    if not toplevel then return nil end

    local ok, out = pcall(function()
        return Job:new({
            command = "git",
            args = { "-C", cwd, "status", "--porcelain=v1", "-z", "--untracked-files=normal" },
        }):sync()
    end)
    if not ok or not out then return nil end

    local blob = table.concat(out, "\n")
    if blob == "" then return {} end

    local result = {}
    local i, n = 1, #blob

    local function read_nul(idx)
        local j = blob:find("\0", idx, true)
        if not j then return nil, n + 1 end
        return blob:sub(idx, j - 1), j + 1
    end

    while i <= n do
        local rec
        rec, i = read_nul(i)
        if not rec then break end
        if #rec >= 4 then
            local xy = rec:sub(1, 2)
            local path = rec:sub(4)

            local x, y = xy:sub(1, 1), xy:sub(2, 2)
            if x == "R" or y == "R" or x == "C" or y == "C" then
                local newpath
                newpath, i = read_nul(i)
                if newpath and newpath ~= "" then path = newpath end
            end

            path = (path or ""):gsub("\\", "/")
            if path ~= "" then
                local abs = normpath(toplevel .. "/" .. path) or (toplevel .. "/" .. path)
                result[abs] = git_label_from_xy(xy)
            end
        end
    end
    return result
end

--==============================================================
-- Tree building + scanning
--==============================================================
local function split_dots(name)
    local t = {}
    for seg in string.gmatch(name or "", "([^.]+)") do
        t[#t + 1] = seg
    end
    return t
end

local function sorted_child_segments(node)
    local segs = {}
    for seg, _ in pairs(node.children or {}) do
        segs[#segs + 1] = seg
    end
    table.sort(segs)
    return segs
end

local function node_has_children(node)
    return node and node.children and next(node.children) ~= nil
end

local function build_tree(files, git_map)
    local root = {
        seg = nil,
        full = "",
        children = {},
        file = nil,
        git = "clean",
        creation_ms = 0,
        update_ms = 0,
    }

    for _, item in ipairs(files) do
        local parts = split_dots(item.note)
        local node = root
        local acc = {}

        for _, seg in ipairs(parts) do
            acc[#acc + 1] = seg
            node.children[seg] = node.children[seg] or {
                seg = seg,
                full = table.concat(acc, "."),
                children = {},
                file = nil,
                git = "clean",
                creation_ms = 0,
                update_ms = 0,
            }
            node = node.children[seg]
        end

        node.file = item.path
        node.git = (git_map and item.path and git_map[item.path]) or node.git
        node.creation_ms = item.creation_ms or 0
        node.update_ms = item.update_ms or 0
    end

    local function dfs(n)
        local best_git = n.git or "clean"
        local min_creation = (n.creation_ms or 0)
        local max_update = (n.update_ms or 0)

        for _, c in pairs(n.children or {}) do
            dfs(c)
            best_git = git_worst(best_git, c.git)

            local cc = (c.creation_ms or 0)
            if cc > 0 then
                min_creation = (min_creation == 0) and cc or math.min(min_creation, cc)
            end

            max_update = math.max(max_update, (c.update_ms or 0))
        end

        n.git = best_git
        n.creation_ms = min_creation
        n.update_ms = max_update
    end
    dfs(root)
    return root
end

local function locate_node(root, segments)
    local node = root
    for _, seg in ipairs(segments or {}) do
        if not node.children or not node.children[seg] then
            return root
        end
        node = node.children[seg]
    end
    return node
end

local function stack_prefix(stack)
    if not stack or #stack == 0 then return "" end
    return table.concat(stack, ".")
end

local function normalize_columns(columns)
    local spec = { cols = {}, git_override = nil }
    if type(columns) ~= "table" then return spec end

    if type(columns.git) == "table" then
        spec.git_override = columns.git
        spec.cols[#spec.cols + 1] = "git"
    end

    local seen = { git = (spec.git_override ~= nil) }
    for _, c in ipairs(columns) do
        if type(c) == "string" and c ~= "" and not seen[c] then
            spec.cols[#spec.cols + 1] = c
            seen[c] = true
        end
    end
    return spec
end

local function scan_notes_tree(cfg)
    if not (scandir and Path) then
        vim.notify("[Ma] plenary.nvim is required", vim.log.levels.ERROR)
        return nil, nil, nil
    end

    local cwd = normpath(cfg.cwd) or normpath(vim.fn.getcwd())
    local respect_gitignore = (cfg.respect_gitignore ~= false)

    local colspec = normalize_columns(cfg.columns or M._config.columns or {})
    local need_git = false
    for _, c in ipairs(colspec.cols) do
        if c == "git" then need_git = true break end
    end

    local git_map = need_git and build_git_status_map(cwd) or nil

    local paths = scandir.scan_dir(cwd, {
        hidden = false,
        add_dirs = false,
        depth = cfg.depth,
        respect_gitignore = respect_gitignore,
    })

    local sort = cfg.sort or M._config.sort or {}
    local by = sort.by or "name"
    local need_times = (by == "update" or by == "creation")

    local files = {}
    for _, abs in ipairs(paths) do
        if is_note_file(abs) then
            abs = normpath(abs) or abs
            local rel = abs
            local pobj = P(abs)
            if pobj and pobj.make_relative then
                rel = pobj:make_relative(cwd)
            else
                local a = abs:gsub("\\", "/")
                local c = (cwd or ""):gsub("\\", "/"):gsub("/+$", "")
                rel = (c ~= "" and a:sub(1, #c) == c) and a:sub(#c + 2) or a
            end

            rel = (rel or ""):gsub("\\", "/")
            local note_full = rel:gsub("%.[^.]+$", ""):gsub("/", ".")
            local creation_ms, update_ms = 0, 0

            if need_times then
                creation_ms, update_ms = file_times_ms(abs)
            end

            files[#files + 1] = {
                path = abs,
                note = note_full,
                creation_ms = creation_ms,
                update_ms = update_ms,
            }
        end
    end
    return cwd, build_tree(files, git_map), git_map
end

--==============================================================
-- Buffer / frontmatter maintenance
--==============================================================
local function update_frontmatter_updated(bufnr)
    bufnr = bufnr or 0
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines < 3 or lines[1] ~= "---" then return end

    local fm_end
    for i = 2, math.min(#lines, 200) do
        if lines[i] == "---" then fm_end = i break end
    end
    if not fm_end then return end

    local updated_idx
    for i = 2, fm_end - 1 do
        if lines[i]:match("^updated:%s*.+%s*$") then
            updated_idx = i
            break
        end
    end
    if not updated_idx then return end

    local stamp = format_stamp(M._config.date_format_frontmatter, nil)
    vim.api.nvim_buf_set_lines(bufnr, updated_idx - 1, updated_idx, false, {
        ("updated: %s"):format(stamp),
    })
end

local function retarget_open_buffers(old_to_new)
    local norm_map = {}
    for old, new in pairs(old_to_new or {}) do
        norm_map[normpath(old) or old] = normpath(new) or new
    end

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = vim.api.nvim_buf_get_name(b)
            local new = norm_map[normpath(name) or name]
            if new then vim.api.nvim_buf_set_name(b, new) end
        end
    end
end

local function wipe_buffers_for_paths(paths)
    local lookup = {}
    for _, p in ipairs(paths or {}) do
        if p then lookup[normpath(p) or p] = true end
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = normpath(vim.api.nvim_buf_get_name(b)) or vim.api.nvim_buf_get_name(b)
            if lookup[name] then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
    end
end

--==============================================================
-- Prompts (cmdline/UI)
--==============================================================
local function prompt_ync(message)
    vim.cmd("redraw")
    local ans = vim.fn.input(string.format("%s (y/n/c): ", message))
    ans = (ans or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if ans == "" or ans == "c" or ans == "cancel" then return nil end
    if ans == "y" or ans == "yes" then return "y" end
    if ans == "n" or ans == "no" then return "n" end
    return nil
end

local function ask_cmdline(prompt, default, cb)
    vim.cmd("redraw")
    local s = vim.fn.input(prompt, default or "")
    cb(s)
end

local function ask_ui(prompt, default, cb)
    vim.ui.input({ prompt = prompt, default = default or "" }, cb)
end

--==============================================================
-- Batch rename safety + mechanics
--==============================================================
local function ensure_unique_targets(pairs)
    local seen = {}
    for _, it in ipairs(pairs or {}) do
        if it.to and seen[it.to] then
            return false, ("duplicate target path: %s"):format(it.to)
        end
        if it.to then seen[it.to] = true end
        if it.to and exists(it.to) then
            return false, ("target already exists: %s"):format(it.to)
        end
    end
    return true
end

local function do_batch_rename(pairs)
    table.sort(pairs, function(a, b) return #(a.from or "") > #(b.from or "") end)

    local old_to_new = {}
    for _, it in ipairs(pairs) do
        if it.from and it.to then old_to_new[it.from] = it.to end
    end

    retarget_open_buffers(old_to_new)
    for _, it in ipairs(pairs) do
        if it.from and it.to then rename_file(it.from, it.to) end
    end
end

--==============================================================
-- Create helpers (normalization + prompt chain)
--==============================================================
local function normalize_note_full(s)
    s = trim(s or "")
    if s == "" then return "" end

    s = s:gsub("\\", "/")
    s = s:gsub("^%./", "")
    s = s:gsub("/", ".")
    s = s:gsub("%s+", "-")
    s = s:gsub("%.%.+", ".")
    s = s:gsub("^%.*", ""):gsub("%.*$", "")
    s = s:gsub("%.+", ".")
    s = s:gsub("^%.", ""):gsub("%.$", "")

    return s
end

local function note_path(cwd, note_full)
    return cwd .. "/" .. note_full .. ".md"
end

local function default_from_prefix(prefix_hint)
    prefix_hint = trim(prefix_hint or "")
    if prefix_hint == "" then return "" end
    return (prefix_hint:sub(-1) == ".") and prefix_hint or (prefix_hint .. ".")
end

local function prompt_note_full(ask, default, cb)
    ask("New note ('.' for levels, '-' for names): ", default or "", function(input)
        local raw = input or ""
        local trimmed = trim(raw)

        if raw ~= "" and trimmed == "" then
            vim.notify("Note name cannot consist only of whitespace", vim.log.levels.WARN)
            return cb(nil)
        end

        trimmed = trimmed:gsub("%.[mM][dD]$", "")
        trimmed = trimmed:gsub("%.[mM][aA][rR][kK][dD][oO][wW][nN]$", "")

        local note_full = normalize_note_full(trimmed)
        if note_full == "" then return cb(nil) end
        cb(note_full)
    end)
end

local function prompt_title(ask, note_full, cb)
    local suggested = title_from_note_name(note_full)
    ask("Title (optional): ", suggested, function(title)
        title = trim(title)
        cb((title ~= "" and title) or suggested)
    end)
end

local function prompt_desc(ask, cb)
    ask("Desc (optional): ", "", function(desc)
        cb(desc or "")
    end)
end

local function ensure_note_file(path, note_full, title, desc)
    return write_file_if_missing(path, frontmatter_text(note_full, title, desc))
end

--==============================================================
-- Create / Open separation (small, focused functions)
--==============================================================
local function prompt_note_meta(opts, ask, cb)
    opts = opts or {}

    local function with_desc(note_full, title)
        if opts.ask_desc == false then
            return cb(note_full, title, "")
        end
        prompt_desc(ask, function(desc)
            cb(note_full, title, desc or "")
        end)
    end

    local function with_title(note_full)
        if opts.title and opts.title ~= "" then
            return with_desc(note_full, opts.title)
        end
        prompt_title(ask, note_full, function(title)
            with_desc(note_full, title)
        end)
    end

    local function with_note_full()
        if opts.note_full and opts.note_full ~= "" then
            return with_title(opts.note_full)
        end
        local default = default_from_prefix(opts.prefix_hint)
        prompt_note_full(ask, default, function(note_full)
            if not note_full then return cb(nil, nil, nil) end
            with_title(note_full)
        end)
    end

    with_note_full()
end

-- Creates a note file with frontmatter if the file does not exist.
-- Does NOT modify existing files.
local function create_note_file(cwd, note_full, title, desc, opts)
    opts = opts or {}
    local refuse_overwrite = (opts.refuse_overwrite ~= false) -- default true

    local path = note_path(cwd, note_full)

    if refuse_overwrite and exists(path) then
        return false, path
    end

    local created = ensure_note_file(path, note_full, title, desc or "")
    return created, path
end

local function open_existing_note(cwd, note_full)
    local path = note_path(cwd, note_full)
    if exists(path) then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        return true, path
    end
    return false, path
end

local function open_or_create_note(opts, cwd, ask, done)
    opts = opts or {}

    if opts.note_full and opts.note_full ~= "" then
        local opened, path = open_existing_note(cwd, opts.note_full)
        if opened then
            return done({
                created = false,
                opened = true,
                path = path,
                note_full = opts.note_full,
            })
        end
    end

    prompt_note_meta(opts, ask, function(note_full, title, desc)
        if not note_full then
            return done({
                created = false,
                opened = false,
                path = nil,
                note_full = nil,
            })
        end

        local created, path = create_note_file(cwd, note_full, title, desc, { refuse_overwrite = true })

        local opened, _ = open_existing_note(cwd, note_full)

        return done({
            created = created,
            opened = opened,
            path = opened and path or nil,
            note_full = note_full,
            title = title,
            desc = desc,
        })
    end)
end

local function create_note_flexible(cwd, prefix_hint, ask, done)
    maybe_chdir_to_active_root()
    open_or_create_note({ prefix_hint = prefix_hint, ask_desc = true }, cwd, ask, function(res)
        done(res and res.created or false)
    end)
end

--==============================================================
-- Daily notes
--==============================================================
local function format_daily_stamp()
    local d = M._config.daily_notes
    if d == false then return nil end
    if type(d) ~= "table" then d = {} end

    local fmt = d.date_format
    local loc = d.locale
    return format_stamp(fmt, loc) -- default handled inside format_stamp
end

local function daily_note_full_and_stamp()
    local stamp = format_daily_stamp()
    if not stamp then return nil, nil end
    return "daily." .. stamp, stamp
end

local function open_or_create_daily(cwd, ask, done)
    maybe_chdir_to_active_root()
    local note_full, stamp = daily_note_full_and_stamp()
    if not note_full then
        vim.notify("[Ma] daily notes are disabled (daily_notes=false)", vim.log.levels.WARN)
        return done(false)
    end

    open_or_create_note({
        note_full = note_full,
        title = stamp,
        ask_desc = true,
    }, cwd, ask, function(res)
        done(res and res.created or false)
    end)
end

--==============================================================
-- Current-buffer helpers (prefix + managed note detection)
--==============================================================
local function note_parent_prefix_from_buf(cwd)
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then return "" end
    if not is_under(path, cwd) then return "" end
    if not is_note_file(path) then return "" end

    local base = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "")
    local parts = split_dots(base)
    if #parts <= 1 then return "" end
    table.remove(parts, #parts)
    return table.concat(parts, ".")
end

local function current_note_path_if_managed()
    local root = active_root()
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return nil end
    if not is_under(file, root) then return nil end
    if not is_note_file(file) then return nil end
    return normpath(file) or file
end

--==============================================================
-- Link from visual selection: :Ma link
--==============================================================
local function get_visual_selection_range_and_text()
    local bufnr = vim.api.nvim_get_current_buf()

    local sp = vim.fn.getpos("'<")
    local ep = vim.fn.getpos("'>")
    if not sp or not ep then return nil end

    local srow, scol = sp[2], sp[3] -- 1-based, inclusive
    local erow, ecol = ep[2], ep[3] -- 1-based, inclusive
    if not (srow and scol and erow and ecol) then return nil end

    if erow < srow or (erow == srow and ecol < scol) then
        srow, erow = erow, srow
        scol, ecol = ecol, scol
    end

    local srow0, scol0 = srow - 1, math.max(0, scol - 1)
    local erow0 = erow - 1
    local ecol_excl = math.max(0, ecol)

    -- clamp end col to last line length (handles linewise selections / huge ecol)
    local last = vim.api.nvim_buf_get_lines(bufnr, erow0, erow0 + 1, false)[1] or ""
    local max_excl = #last
    if ecol_excl > max_excl then ecol_excl = max_excl end

    local chunks = vim.api.nvim_buf_get_text(bufnr, srow0, scol0, erow0, ecol_excl, {})
    local text = table.concat(chunks, "\n")
    if text == "" then return nil end

    return {
        bufnr = bufnr,
        srow0 = srow0,
        scol0 = scol0,
        erow0 = erow0,
        ecol0_excl = ecol_excl,
        text = text,
    }
end

local function ma_link_from_visual()
    maybe_chdir_to_active_root()
    local cwd = active_root()

    -- Must be a managed note (so "same root/folder/path" makes sense)
    local cur = vim.api.nvim_buf_get_name(0)
    if cur == "" or not is_under(cur, cwd) or not is_note_file(cur) then
        vim.notify("[Ma] link: current buffer is not a managed note under vault/cwd", vim.log.levels.WARN)
        return
    end

    local sel = get_visual_selection_range_and_text()
    if not sel or not sel.text then
        vim.notify("[Ma] link: no visual selection", vim.log.levels.WARN)
        return
    end

    local label = sel.text
    local suffix = normalize_note_full(trim(label)):lower()
    if suffix == "" then
        vim.notify("[Ma] link: selection cannot produce a valid note name", vim.log.levels.WARN)
        return
    end

    local prefix = note_parent_prefix_from_buf(cwd) -- may be "" for root notes, that's fine
    local default_full = (prefix ~= "" and (prefix .. "." .. suffix)) or suffix

    -- Save range now; only mutate after successful creation
    local src_buf = sel.bufnr
    local srow0, scol0 = sel.srow0, sel.scol0
    local erow0, ecol0_excl = sel.erow0, sel.ecol0_excl

    -- Reuse your existing prompt + normalization rules
    prompt_note_full(ask_cmdline, default_full, function(note_full)
        if not note_full then return end
        note_full = normalize_note_full(trim(note_full)):lower()
        if note_full == "" then return end

        open_or_create_note({
            note_full = note_full,
            ask_desc = true,
        }, cwd, ask_cmdline, function(res)
            -- Only after the note has been created do we convert selection into a link
            if not res or not res.created then return end

            local target = note_full .. ".md"
            local repl = ("[%s](%s)"):format(label, target)

            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(src_buf) then return end
                vim.api.nvim_buf_set_text(src_buf, srow0, scol0, erow0, ecol0_excl, { repl })
            end)
        end)
    end)
end

--==============================================================
-- Actions (rename/delete + current-buffer variants)
--==============================================================
local actions = {}

local function delete_one(path)
    if not path or path == "" then return false end
    return (M._config.delete_to_trash and trash_file(path)) or rm_file(path)
end

local function delete_verb()
    return (M._config.delete_to_trash and "trashed") or "deleted"
end

local function gather_files_under(node)
    local out = {}
    if node.file then out[#out + 1] = node.file end
    for _, seg in ipairs(sorted_child_segments(node)) do
        local child = node.children[seg]
        local sub = gather_files_under(child)
        for _, p in ipairs(sub) do out[#out + 1] = p end
    end
    return out
end

local function gather_note_files_with_full(node)
    local out = {}
    if node.file then out[#out + 1] = { full = node.full, path = node.file } end
    for _, seg in ipairs(sorted_child_segments(node)) do
        local child = node.children[seg]
        local sub = gather_note_files_with_full(child)
        for _, it in ipairs(sub) do out[#out + 1] = it end
    end
    return out
end

function actions.rename(cwd, selection, on_done)
    if not selection or selection.kind == "back" then return on_done(false) end

    if selection.kind == "folder" then
        local old_prefix = selection.full or selection.name
        vim.ui.input({
            prompt = ("Rename folder '%s' to (full prefix): "):format(old_prefix),
            default = old_prefix,
        }, function(new_prefix)
            new_prefix = trim(new_prefix)
            if new_prefix == "" then return on_done(false) end

            local items = gather_note_files_with_full(selection.node)
            if #items == 0 then
                vim.notify("[Ma] folder has no note files to rename", vim.log.levels.WARN)
                return on_done(false)
            end

            local pairs = {}
            for _, it in ipairs(items) do
                local rest = (it.full == old_prefix) and "" or it.full:sub(#old_prefix + 1)
                local new_full = new_prefix .. rest
                pairs[#pairs + 1] = { from = it.path, to = cwd .. "/" .. new_full .. ".md" }
            end

            local ok, err = ensure_unique_targets(pairs)
            if not ok then
                vim.notify("[Ma] rename aborted: " .. err, vim.log.levels.ERROR)
                return on_done(false)
            end

            do_batch_rename(pairs)
            vim.notify(
                ("[Ma] renamed folder '%s' -> '%s' (%d files)"):format(old_prefix, new_prefix, #pairs),
                vim.log.levels.INFO
            )
            on_done(true)
        end)
        return
    end

    if not selection.path then
        vim.notify("[Ma] no file exists for this node", vim.log.levels.WARN)
        return on_done(false)
    end

    local old_full = selection.full or selection.name
    vim.ui.input({
        prompt = ("Rename '%s' to: "):format(old_full),
        default = old_full,
    }, function(new_full)
        new_full = trim(new_full)
        if new_full == "" then return on_done(false) end

        local pairs = { { from = selection.path, to = cwd .. "/" .. new_full .. ".md" } }
        local ok, err = ensure_unique_targets(pairs)
        if not ok then
            vim.notify("[Ma] rename aborted: " .. err, vim.log.levels.ERROR)
            return on_done(false)
        end

        do_batch_rename(pairs)
        vim.notify(("[Ma] renamed '%s' -> '%s'"):format(old_full, new_full), vim.log.levels.INFO)
        on_done(true)
    end)
end

function actions.delete(selection, on_done)
    -- normalize to list
    local sels = (type(selection) == "table" and rawget(selection, 1) ~= nil) and selection or { selection }

    local paths = {}
    local item_count = 0
    local first_sel = nil

    for _, sel in ipairs(sels) do
        if sel and sel.kind ~= "back" then
            item_count = item_count + 1
            if not first_sel then first_sel = sel end

            if sel.kind == "folder" then
                local sub = gather_files_under(sel.node)
                for _, p in ipairs(sub) do paths[#paths + 1] = p end
            elseif sel.path then
                paths[#paths + 1] = sel.path
            end
        end
    end

    if item_count == 0 then
        return on_done(false)
    end

    if #paths == 0 then
        -- consistent with your current messaging for "no file exists"
        if item_count == 1 then
            vim.notify("[Ma] no file exists for this node", vim.log.levels.WARN)
        else
            vim.notify("[Ma] nothing to delete", vim.log.levels.WARN)
        end
        return on_done(false)
    end

    -- prompt (preserve your single-item wording)
    local msg
    if item_count == 1 then
        if first_sel.kind == "folder" then
            msg = ("Delete folder '%s' and %d note(s)?"):format(first_sel.full or first_sel.name, #paths)
        else
            msg = ("Delete note '%s'?"):format(first_sel.full or first_sel.name)
        end
    else
        msg = ("Delete %d selected item(s) and %d note(s)?"):format(item_count, #paths)
    end

    local ans = prompt_ync(msg)
    if ans ~= "y" then return on_done(false) end

    wipe_buffers_for_paths(paths)
    for _, p in ipairs(paths) do delete_one(p) end
    vim.notify(("[Ma] %s %d file(s)"):format(delete_verb(), #paths), vim.log.levels.INFO)
    return on_done(true)
end

function actions.rename_current_buffer()
    local path = current_note_path_if_managed()
    if not path then
        vim.notify("[Ma] current buffer is not a managed note under vault/cwd", vim.log.levels.WARN)
        return
    end

    local cwd = active_root()
    local base = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "")

    vim.ui.input({
        prompt = ("Rename '%s' to (full name): "):format(base),
        default = base,
    }, function(new_full)
        new_full = trim(new_full)
        if new_full == "" then return end

        local to = cwd .. "/" .. new_full .. ".md"
        local pairs = { { from = path, to = to } }

        local ok, err = ensure_unique_targets(pairs)
        if not ok then
            vim.notify("[Ma] rename aborted: " .. err, vim.log.levels.ERROR)
            return
        end

        do_batch_rename(pairs)
        vim.notify(("[Ma] renamed '%s' -> '%s'"):format(base, new_full), vim.log.levels.INFO)
        vim.cmd("edit " .. vim.fn.fnameescape(to))
    end)
end

function actions.delete_current_buffer()
    local path = current_note_path_if_managed()
    if not path then
        vim.notify("[Ma] current buffer is not a managed note under vault/cwd", vim.log.levels.WARN)
        return
    end

    local base = (path:match("([^/]+)$") or path)
    local ans = prompt_ync(("Delete note '%s'?"):format(base))
    if ans ~= "y" then return end

    wipe_buffers_for_paths({ path })
    delete_one(path)
    vim.notify(("[Ma] %s 1 file"):format(delete_verb()), vim.log.levels.INFO)
end

--==============================================================
-- Telescope integration (deps + UI)
--==============================================================
local function telescope_deps()
    local pickers = safe_require("telescope.pickers")
    local finders = safe_require("telescope.finders")
    local cfgmod = safe_require("telescope.config")
    local conf = cfgmod and cfgmod.values or nil
    local entry_display = safe_require("telescope.pickers.entry_display")
    local actions_t = safe_require("telescope.actions")
    local action_state = safe_require("telescope.actions.state")
    local previewers = safe_require("telescope.previewers")

    if not (pickers and finders and conf and entry_display and actions_t and action_state) then
        return nil
    end

    return {
        pickers = pickers,
        finders = finders,
        conf = conf,
        entry_display = entry_display,
        actions = actions_t,
        action_state = action_state,
        previewers = previewers,
    }
end

local function safe_previewer(t)
    if not t or not t.previewers then return nil end
    local p = t.previewers
    local utils = safe_require("telescope.previewers.utils")

    if p.vim_buffer_cat and type(p.vim_buffer_cat.new) == "function" then
        local ok, res = pcall(function() return p.vim_buffer_cat.new({}) end)
        if ok and res then return res end
    end

    if p.new_buffer_previewer then
        local ok, res = pcall(function()
            return p.new_buffer_previewer({
                define_preview = function(self, entry, status)
                    local path = entry and entry.value and entry.value.path
                    if not path or path == "" then return end

                    local bufnr = self.state.bufnr
                    local winid = (status and (status.preview_win or status.preview_winid)) or self.state.winid

                    local lines = vim.fn.readfile(path, "", 200)
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                    local ft = vim.filetype.match({ filename = path }) or "markdown"
                    if self.state._ma_last_ft ~= ft then
                        self.state._ma_last_ft = ft
                        vim.api.nvim_buf_call(bufnr, function()
                            pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", ft)
                            if utils and utils.highlighter then
                                pcall(utils.highlighter, bufnr, ft)
                            else
                                pcall(vim.api.nvim_buf_set_option, bufnr, "syntax", ft)
                            end
                        end)
                    end

                    if self.state._ma_last_path ~= path then
                        self.state._ma_last_path = path
                        if winid and vim.api.nvim_win_is_valid(winid) then
                            vim.schedule(function()
                                if vim.api.nvim_win_is_valid(winid) then
                                    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
                                    vim.api.nvim_win_call(winid, function() vim.cmd("normal! zt") end)
                                end
                            end)
                        end
                    end
                end,
            })
        end)
        if ok and res then return res end
    end

    if p.cat and type(p.cat.new) == "function" then
        local ok, res = pcall(function() return p.cat.new({}) end)
        if ok and res then return res end
    end

    return nil
end

local function ma_initial_mode()
    local m = M._config.telescope_initial_mode
    return (m == "normal" or m == "insert") and m or "insert"
end

local function pick_vault()
    local t = telescope_deps()
    if not t then
        vim.notify("[Ma.nvim] telescope.nvim is required", vim.log.levels.ERROR)
        return
    end

    local vaults = normalize_vaults(M._config.vaults)
    if not vaults then
        vim.notify("[Ma.nvim] no vaults configured", vim.log.levels.WARN)
        return
    end

    t.pickers.new({ initial_mode = ma_initial_mode() }, {
        prompt_title = "Ma: vault",
        finder = t.finders.new_table({
            results = vaults,
            entry_maker = function(v)
                return {
                    value = v,
                    ordinal = (v.name or "") .. " " .. (v.path or ""),
                    display = v.name or v.path,
                }
            end,
        }),
        sorter = t.conf.generic_sorter({}),
        attach_mappings = function(bufnr, map)
            local function choose()
                local sel = t.action_state.get_selected_entry()
                local v = sel and sel.value
                if not v then return end
                t.actions.close(bufnr)
                M._config._active_vault = v
                vim.schedule(function() M.navigate() end)
            end
            map("i", "<CR>", choose)
            map("n", "<CR>", choose)
            return true
        end,
    }):find()
end

--==============================================================
-- Sorting (multi-key + fallback)
--==============================================================
local function is_list(t)
    if type(t) ~= "table" then return false end
    local n = #t
    for i = 1, n do
        if rawget(t, i) == nil then return false end
    end
    -- if it has non-array keys too, we still treat it as list for our purposes
    return true
end

local function navigator(cfg)
    local t = telescope_deps()
    if not t then
        vim.notify("[Ma.nvim] telescope.nvim is required", vim.log.levels.ERROR)
        return
    end

    local devicons = safe_require("nvim-web-devicons")

    local colspec = normalize_columns(cfg.columns or M._config.columns or {})
    local columns = colspec.cols
    local git_symbols = colspec.git_override or DEFAULT_GIT_SYMBOLS
    local git_override = colspec.git_override

    local stack = {}
    local cwd, root = scan_notes_tree(cfg)
    if not root then return end

    local function rescan()
        cwd, root = scan_notes_tree(cfg)
        return root ~= nil
    end

    local function current_node()
        return locate_node(root, stack)
    end

    local function title_for()
        local prefix = stack_prefix(stack)

        local v = M._config._active_vault
        local has_vaults = type(M._config.vaults) == "table" and #M._config.vaults > 0
        local vault_name = (has_vaults and v and v.name and v.name ~= "") and v.name or nil

        local base = vault_name and ("Ma: " .. vault_name) or "Ma"
        return (prefix == "") and base or (base .. " · " .. prefix)
    end

    local function picker_actions_list()
        local pa = M._config.picker_actions
        if pa == false then return {} end
        if type(pa) ~= "table" then return {} end

        local out = {}
        if is_list(pa) then
            -- ordered: { {"c","create"}, {"r","rename"} }
            for _, it in ipairs(pa) do
                local k, act = it[1], it[2]
                if type(k) == "string" and #k == 1 and type(act) == "string" and act ~= "" then
                    out[#out + 1] = { k = k, act = act }
                end
            end
            return out
        end

        -- legacy map form: stable order by key
        for k, act in pairs(pa) do
            if type(k) == "string" and #k == 1 and type(act) == "string" and act ~= "" then
                out[#out + 1] = { k = k, act = act }
            end
        end
        table.sort(out, function(a, b) return a.k < b.k end)
        return out
    end

    local ACTIONS = picker_actions_list()

    local function results_title()
        local results_parts = { "Enter: open", "<BS>/`-`: back parent dir" }
        if #ACTIONS > 0 then
            local labels = {}
            for _, it in ipairs(ACTIONS) do
                labels[#labels + 1] = ("%s: %s"):format(it.k, it.act)
            end
            results_parts[#results_parts + 1] = "[" .. table.concat(labels, ", ") .. "]"
        end
        return table.concat(results_parts, ", ")
    end

    local display_items = {}
    for _, c in ipairs(columns) do
        if c == "git" or c == "icon" then
            display_items[#display_items + 1] = { width = 2 }
        end
    end
    display_items[#display_items + 1] = { remaining = true }

    local displayer = t.entry_display.create({ separator = " ", items = display_items })

    local function icon_for(v)
        if v.kind == "folder" then return "" end
        if devicons and devicons.get_icon then
            local filename = v.path and v.path:match("([^/\\]+)$") or (v.name .. ".md")
            local ext = filename:match("%.([^.]+)$") or ""
            return devicons.get_icon(filename, ext, { default = true }) or "󰈙"
        end
        return "󰈙"
    end

    local git_for
    if git_override then
        git_for = function(v)
            if v.kind == "back" then return "" end
            return (git_symbols[v.git or "clean"] or "")
        end
    else
        local unknown = git_symbols.unknown or ""
        git_for = function(v)
            if v.kind == "back" then return "" end
            return (git_symbols[v.git or "clean"] or unknown)
        end
    end

    local function make_display(v)
        local cols = {}
        for _, c in ipairs(columns) do
            if c == "git" then cols[#cols + 1] = { git_for(v) } end
            if c == "icon" then cols[#cols + 1] = { icon_for(v) } end
        end
        cols[#cols + 1] = { v.name or "(unknown)" }
        return displayer(cols)
    end

    local function build_entries(node)
        local results = {}

        for _, seg in ipairs(sorted_child_segments(node)) do
            local child = node.children[seg]
            local is_folder = node_has_children(child)

            results[#results + 1] = {
                kind = is_folder and "folder" or "file",
                name = seg,
                node = child,
                path = child.file,
                full = child.full,
                git = child.git or "clean",
            }
        end

        local s = cfg.sort or M._config.sort or {}
        local by = s.by or "name"
        local desc = (s.order == "desc")

        local function key(v)
            if by == "update" then
                return tonumber(v.node and v.node.update_ms) or 0
            elseif by == "creation" then
                return tonumber(v.node and v.node.creation_ms) or 0
            else -- "name"
                return tostring(v.name or ""):lower()
            end
        end

        table.sort(results, function(a, b)
            local ka, kb = key(a), key(b)
            if ka ~= kb then
                if desc then return ka > kb else return ka < kb end
            end
            -- strict deterministic fallback to avoid "invalid order function"
            local fa = tostring(a.full or a.name or "")
            local fb = tostring(b.full or b.name or "")
            if fa ~= fb then return fa < fb end
            return false
        end)

        return results
    end

    local function make_finder(node)
        local entries = build_entries(node)
        return t.finders.new_table({
            results = entries,
            entry_maker = function(item)
                local p = (type(item.path) == "string") and item.path or ""
                return {
                    value = item,
                    ordinal = item.full or item.name,
                    display = function(e) return make_display(e.value) end,
                    path = p,
                    filename = p,
                }
            end,
        })
    end

    local open_picker

    open_picker = function()
        local node = current_node()

        t.pickers.new({ initial_mode = ma_initial_mode() }, {
            prompt_title = title_for(),
            results_title = results_title(),
            finder = make_finder(node),
            sorter = t.conf.generic_sorter({}),
            previewer = safe_previewer(t),

            attach_mappings = function(bufnr, map)
                local picker = t.action_state.get_current_picker(bufnr)

                local function refresh(reset_prompt)
                    picker.prompt_title = title_for()
                    picker.results_title = results_title()
                    picker:refresh(make_finder(current_node()), { reset_prompt = (reset_prompt == true) })
                end

                local function go_up(force)
                    if #stack == 0 then return end
                    if not force then
                        local line = t.action_state.get_current_line() or ""
                        if line ~= "" then return end
                    end
                    table.remove(stack, #stack)
                    refresh(true)
                end

                local function enter()
                    local sel = t.action_state.get_selected_entry()
                    local v = sel and sel.value
                    if not v then return end

                    if v.kind == "folder" then
                        stack[#stack + 1] = v.name
                        refresh(true)
                        return
                    end

                    t.actions.close(bufnr)
                    if v.path then
                        vim.schedule(function()
                            vim.cmd("edit " .. vim.fn.fnameescape(v.path))
                        end)
                    end
                end

                local function selection()
                    local sel = t.action_state.get_selected_entry()
                    return sel and sel.value or nil
                end

                local function done(changed)
                    if changed then rescan() end
                    open_picker()
                end

                local function done_no_reopen(changed)
                    if changed then rescan() end
                end

                local function run_create()
                    t.actions.close(bufnr)
                    local prefix = stack_prefix(stack)
                    vim.schedule(function()
                        create_note_flexible(cwd, prefix, ask_ui, done_no_reopen)
                    end)
                end

                local function run_rename()
                    local entries = picker:get_multi_selection() or {}
                    local n = 0
                    local only = nil

                    if #entries > 0 then
                        for _, e in ipairs(entries) do
                            local v = e and e.value
                            if v and v.kind ~= "back" then
                                n = n + 1
                                only = v
                                if n > 1 then break end
                            end
                        end
                    else
                        local v = selection()
                        if v and v.kind ~= "back" then
                            n = 1
                            only = v
                        end
                    end

                    if n ~= 1 or not only then
                        vim.notify("[Ma] rename requires a single item selection", vim.log.levels.WARN)
                        return
                    end

                    t.actions.close(bufnr)
                    vim.schedule(function()
                        actions.rename(cwd, only, done)
                    end)
                end

                local function run_delete()
                    local entries = picker:get_multi_selection() or {}
                    local values = {}

                    if #entries > 0 then
                        for _, e in ipairs(entries) do
                            local v = e and e.value
                            if v and v.kind ~= "back" then
                                values[#values + 1] = v
                            end
                        end
                    else
                        local v = selection()
                        if v and v.kind ~= "back" then
                            values[1] = v
                        end
                    end

                    if #values == 0 then return end

                    t.actions.close(bufnr)
                    vim.schedule(function()
                        actions.delete(values, done)
                    end)
                end

                map("i", "<CR>", enter)
                map("n", "<CR>", enter)

                map("n", "<BS>", function() go_up(false) end)
                map("n", "-", function() go_up(true) end)
                map("i", "<C-h>", function() go_up(true) end)

                for _, it in ipairs(ACTIONS) do
                    map("n", it.k, function()
                        if it.act == "create" then run_create()
                        elseif it.act == "rename" then run_rename()
                        elseif it.act == "delete" then run_delete()
                        end
                    end)
                end

                return true
            end,
        }):find()
    end

    open_picker()
end

--==============================================================
-- Public API
--==============================================================
function M._runtime_cfg()
    local cfg = M._config
    return {
        cwd = active_root(),
        respect_gitignore = cfg.respect_gitignore,
        depth = cfg.depth,
        columns = cfg.columns,
    }
end

function M.navigate()
    maybe_chdir_to_active_root()
    navigator(M._runtime_cfg())
end

function M.link()
    ma_link_from_visual()
end

--==============================================================
-- Commands
--==============================================================
local function create_commands()
    vim.api.nvim_create_user_command("Ma", function(opts)
        local sub = (opts.fargs and opts.fargs[1]) and trim(opts.fargs[1]) or ""

        if sub == "" then
            return M.navigate()
        end

        if sub == "vault" then
            return pick_vault()
        end

        if sub == "daily" then
            local cwd = active_root()
            return open_or_create_daily(cwd, ask_cmdline, function() end)
        end

        if sub == "link" then
            return ma_link_from_visual()
        end

        if sub == "create" then
            local cwd = active_root()
            local prefix = note_parent_prefix_from_buf(cwd)
            return create_note_flexible(cwd, prefix, ask_cmdline, function() end)
        end

        if sub == "rename" then
            return actions.rename_current_buffer()
        end

        if sub == "delete" then
            return actions.delete_current_buffer()
        end

        vim.notify("[Ma] unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end, {
    nargs = "*",
    complete = function()
        return { "create", "link", "rename", "delete", "vault", "daily" }
    end,
})
end

--==============================================================
-- Setup
--==============================================================
M.setup = function(user_opts)
    user_opts = user_opts or {}
    local incoming = vim.deepcopy(user_opts)

    if type(incoming.keymaps) == "table" then
        local looks_like_actions = false
        for k, v in pairs(incoming.keymaps) do
            if type(k) == "string" and #k == 1 and (type(v) == "string" or type(v) == "table") then
                looks_like_actions = true
                break
            end
        end
        if looks_like_actions and incoming.picker_actions == nil then
            incoming.picker_actions = incoming.keymaps
        end
        incoming.keymaps = nil
    end

    if type(incoming.picker_actions) == "table" then
        for k, v in pairs(incoming.picker_actions) do
            if type(k) == "string" and #k == 1 and type(v) == "table" then
                incoming.picker_actions[k] = v[1]
            end
        end
    end

    M._config = vim.tbl_deep_extend("force", M._config, incoming)

    M._config.vaults = normalize_vaults(M._config.vaults)
    if not M._config._active_vault then
        M._config._active_vault = (M._config.vaults and M._config.vaults[1]) or nil
    end

    create_commands()

    local group = vim.api.nvim_create_augroup("MaFrontmatterUpdated", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
        group = group,
        pattern = { "*.md", "*.markdown" },
        callback = function(ev)
            local root = active_root()
            local file = ev.match or vim.api.nvim_buf_get_name(ev.buf)
            if not is_under(file, root) then return end
            update_frontmatter_updated(ev.buf)
        end,
        desc = "Update Dendron-style frontmatter 'updated' timestamp",
    })
end

return M
