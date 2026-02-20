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
    -- If nil or {}, Hematite uses the current working directory as the root.
    -- Hematite uses the "active" vault (default: first).
    vaults = {
        {
            name = "Brain",
            path = "~/Brain/notes"
        },
        {
            name = "test",
            path = "~/Desktop/Test/"
        }
    },
    depth = nil,
    delete_to_trash = true,
    picker_actions = {
        { "c", "create" },
        { "r", "rename" },
        { "d", "delete" },
    },
    columns = { "git", "icon" }, -- can be: { git = { modified="✱ " }, "icon" }
    respect_gitignore = true,
    daily_notes = {
        date_format = nil, -- optional, default ``
        locale = nil, -- optional, default current locale
    }
}

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
    local o = P(p)
    return o and o.exists and o:exists() or false
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
    path = normpath(path) or path:gsub("\\", "/")
    root = (normpath(root) or root:gsub("\\", "/")):gsub("/+$", "")
    return path:sub(1, #root) == root
end

--==============================================================
-- Vault utils
--==============================================================
local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_vaults(vault)
    if type(vault) ~= "table" or vim.tbl_isempty(vault) then return nil end
    local out = {}
    for _, v in ipairs(vault) do
        if type(v) == "table" and type(v.path) == "string" and v.path ~= "" then
            local p = normpath(v.path)
            if p and p ~= "" then
                out[#out + 1] = {
                    name = (type(v.name) == "string" and v.name ~= "") and v.name or p,
                    path = p,
                }
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

--==============================================================
-- Note/frontmatter utils
--==============================================================
local function now_ms()
    return math.floor(os.time() * 1000)
end

local function nanoid_like(len)
    len = len or 23
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    local seed = (vim.uv or vim.loop).hrtime() % 2147483647
    math.randomseed(seed)
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
    local ts = now_ms()
    local id = nanoid_like(23)
    return table.concat({
        "---",
        ("id: %s"):format(id),
        ("title: %s"):format(t),
        ("desc: %s"):format(d),
        ("updated: %d"):format(ts),
        ("created: %d"):format(ts),
        "---",
        "",
    }, "\n")
end

-- Always md/markdown now (removed exts option)
local function is_note_file(path)
    local ext = path:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "md" or ext == "markdown"
end

--==============================================================
-- Daily notes
--==============================================================
local function format_daily_stamp()
    local d = M._config.daily_notes
    if d == false then return nil end
    if type(d) ~= "table" then d = {} end

    local fmt = (type(d.date_format) == "string" and d.date_format ~= "") and d.date_format or "%Y.%b-%d"
    local loc = (type(d.locale) == "string" and d.locale ~= "") and d.locale or nil

    if not loc then
        return os.date(fmt)
    end

    local old = os.setlocale(nil, "time")
    os.setlocale(loc, "time")
    local s = os.date(fmt)
    os.setlocale(old, "time")
    return s
end

local function open_or_create_daily(cwd, ask, done)
    local stamp = format_daily_stamp()
    if not stamp then
        vim.notify("[hematite] daily notes are disabled (daily_notes=false)", vim.log.levels.WARN)
        return done(false)
    end

    local note_full = "daily." .. stamp
    local path = cwd .. "/" .. note_full .. ".md"

    if exists(path) then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        return done(false)
    end

    ask("Desc (optional): ", "", function(desc)
        desc = desc or ""
        -- daily note: title = the date part (the obvious title)
        write_file_if_missing(path, frontmatter_text(note_full, stamp, desc))
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        done(true)
    end)
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
    local root = { seg = nil, full = "", children = {}, file = nil, git = "clean" }

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
            }
            node = node.children[seg]
        end

        node.file = item.path
        node.git = (git_map and item.path and git_map[item.path]) or node.git
    end

    local function dfs(n)
        local best = n.git or "clean"
        for _, c in pairs(n.children or {}) do
            dfs(c)
            best = git_worst(best, c.git)
        end
        n.git = best
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
    if type(columns) ~= "table" then return {}, nil end
    local git_override = (type(columns.git) == "table") and columns.git or nil
    local out, seen = {}, {}

    if git_override then
        out[#out + 1] = "git"
        seen.git = true
    end

    for _, c in ipairs(columns) do
        if type(c) == "string" and c ~= "" and not seen[c] then
            out[#out + 1] = c
            seen[c] = true
        end
    end

    return out, git_override
end

local function scan_notes_tree(cfg)
    if not (scandir and Path) then
        vim.notify("[hematite] plenary.nvim is required", vim.log.levels.ERROR)
        return nil, nil, nil
    end

    local cwd = normpath(cfg.cwd) or normpath(vim.fn.getcwd())
    local respect_gitignore = (cfg.respect_gitignore ~= false)

    local cols = normalize_columns(cfg.columns or M._config.columns or {})
    local need_git = false
    for _, c in ipairs(cols) do
        if c == "git" then need_git = true break end
    end

    local git_map = need_git and build_git_status_map(cwd) or nil

    local paths = scandir.scan_dir(cwd, {
        hidden = false,
        add_dirs = false,
        depth = cfg.depth,
        respect_gitignore = respect_gitignore,
    })

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
            local base = (rel:match("([^/]+)$") or rel):gsub("%.[^.]+$", "")
            files[#files + 1] = { path = abs, note = base }
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
        if lines[i]:match("^updated:%s*%d+%s*$") then
            updated_idx = i
            break
        end
    end
    if not updated_idx then return end

    vim.api.nvim_buf_set_lines(bufnr, updated_idx - 1, updated_idx, false, {
        ("updated: %d"):format(now_ms()),
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
-- Prompts
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

--==============================================================
-- Batch rename safety
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
-- Create (ONE implementation, TWO UI adapters) - FLEXIBLE
--==============================================================
local function ask_cmdline(prompt, default, cb)
    vim.cmd("redraw")
    local s = vim.fn.input(prompt, default or "")
    cb(s)
end

local function ask_ui(prompt, default, cb)
    vim.ui.input({ prompt = prompt, default = default or "" }, cb)
end

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

local function create_note_flexible(cwd, prefix_hint, ask, done)
    prefix_hint = trim(prefix_hint or "")
    local default = prefix_hint
    if default ~= "" and default:sub(-1) ~= "." then default = default .. "." end

    ask("New note ('.' for levels, '-' for names): ", default, function(input)
        local raw = input or ""
        local trimmed = trim(raw)

        if raw ~= "" and trimmed == "" then
            vim.notify("Note name cannot consist only of whitespace", vim.log.levels.WARN)
            return done(false)
        end

        local note_full = normalize_note_full(trimmed)
        if note_full == "" then
            return done(false)
        end

        ask("Title (optional): ", title_from_note_name(note_full), function(title)
            title = trim(title)
            if title == "" then title = title_from_note_name(note_full) end

            ask("Desc (optional): ", "", function(desc)
                desc = desc or ""
                local path = cwd .. "/" .. note_full .. ".md"
                write_file_if_missing(path, frontmatter_text(note_full, title, desc))
                vim.cmd("edit " .. vim.fn.fnameescape(path))
                done(true)
            end)
        end)
    end)
end

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
                vim.notify("[hematite] folder has no note files to rename", vim.log.levels.WARN)
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
                vim.notify("[hematite] rename aborted: " .. err, vim.log.levels.ERROR)
                return on_done(false)
            end

            do_batch_rename(pairs)
            vim.notify(
                ("[hematite] renamed folder '%s' -> '%s' (%d files)"):format(old_prefix, new_prefix, #pairs),
                vim.log.levels.INFO
            )
            on_done(true)
        end)
        return
    end

    if not selection.path then
        vim.notify("[hematite] no file exists for this node", vim.log.levels.WARN)
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
            vim.notify("[hematite] rename aborted: " .. err, vim.log.levels.ERROR)
            return on_done(false)
        end

        do_batch_rename(pairs)
        vim.notify(("[hematite] renamed '%s' -> '%s'"):format(old_full, new_full), vim.log.levels.INFO)
        on_done(true)
    end)
end

function actions.delete(selection, on_done)
    if not selection or selection.kind == "back" then return on_done(false) end

    if selection.kind == "folder" then
        local paths = gather_files_under(selection.node)
        if #paths == 0 then
            vim.notify("[hematite] folder has no note files", vim.log.levels.WARN)
            return on_done(false)
        end

        local ans = prompt_ync(("Delete folder '%s' and %d note(s)?"):format(selection.full or selection.name, #paths))
        if ans ~= "y" then return on_done(false) end

        wipe_buffers_for_paths(paths)
        for _, p in ipairs(paths) do delete_one(p) end
        vim.notify(("[hematite] %s %d file(s)"):format(delete_verb(), #paths), vim.log.levels.INFO)
        return on_done(true)
    end

    if not selection.path then
        vim.notify("[hematite] no file exists for this node", vim.log.levels.WARN)
        return on_done(false)
    end

    local ans = prompt_ync(("Delete note '%s'?"):format(selection.full or selection.name))
    if ans ~= "y" then return on_done(false) end

    wipe_buffers_for_paths({ selection.path })
    delete_one(selection.path)
    vim.notify(("[hematite] %s 1 file"):format(delete_verb()), vim.log.levels.INFO)
    on_done(true)
end

local function current_note_path_if_managed()
    local root = active_root()
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return nil end
    if not is_under(file, root) then return nil end
    if not is_note_file(file) then return nil end
    return normpath(file) or file
end

function actions.rename_current_buffer()
    local path = current_note_path_if_managed()
    if not path then
        vim.notify("[hematite] current buffer is not a managed note under vault/cwd", vim.log.levels.WARN)
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
            vim.notify("[hematite] rename aborted: " .. err, vim.log.levels.ERROR)
            return
        end

        do_batch_rename(pairs)
        vim.notify(("[hematite] renamed '%s' -> '%s'"):format(base, new_full), vim.log.levels.INFO)
        vim.cmd("edit " .. vim.fn.fnameescape(to))
    end)
end

function actions.delete_current_buffer()
    local path = current_note_path_if_managed()
    if not path then
        vim.notify("[hematite] current buffer is not a managed note under vault/cwd", vim.log.levels.WARN)
        return
    end

    local base = (path:match("([^/]+)$") or path)
    local ans = prompt_ync(("Delete note '%s'?"):format(base))
    if ans ~= "y" then return end

    wipe_buffers_for_paths({ path })
    delete_one(path)
    vim.notify(("[hematite] %s 1 file"):format(delete_verb()), vim.log.levels.INFO)
end

--==============================================================
-- Telescope integration
--==============================================================
local function telescope_deps()
    local pickers = safe_require("telescope.pickers")
    local finders = safe_require("telescope.finders")
    local conf = safe_require("telescope.config") and require("telescope.config").values or nil
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
                    if self.state._hematite_last_ft ~= ft then
                        self.state._hematite_last_ft = ft
                        vim.api.nvim_buf_call(bufnr, function()
                            pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", ft)
                            if utils and utils.highlighter then
                                pcall(utils.highlighter, bufnr, ft)
                            else
                                pcall(vim.api.nvim_buf_set_option, bufnr, "syntax", ft)
                            end
                        end)
                    end

                    if self.state._hematite_last_path ~= path then
                        self.state._hematite_last_path = path
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

-- Vault picker: :Hematite vault
local function pick_vault()
    local t = telescope_deps()
    if not t then
        vim.notify("[hematite] telescope.nvim is required", vim.log.levels.ERROR)
        return
    end

    local vaults = normalize_vaults(M._config.vaults)
    if not vaults then
        vim.notify("[hematite] no vaults configured", vim.log.levels.WARN)
        return
    end

    t.pickers.new({}, {
        prompt_title = "Hematite: vault",
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

local function navigator(cfg)
    local t = telescope_deps()
    if not t then
        vim.notify("[hematite] telescope.nvim is required", vim.log.levels.ERROR)
        return
    end

    local devicons = safe_require("nvim-web-devicons")

    local columns, git_override = normalize_columns(cfg.columns or M._config.columns or {})
    local git_symbols = git_override or DEFAULT_GIT_SYMBOLS

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

        local base = vault_name and ("Hematite: " .. vault_name) or "Hematite"
        return (prefix == "") and base or (base .. " · " .. prefix)
    end

    local function picker_actions_list()
        local pa = M._config.picker_actions
        if pa == false then return {} end
        if type(pa) ~= "table" then return {} end

        local out = {}
        if vim.tbl_islist(pa) then
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

    local function results_title()
        local parts = { "Enter: open", "<BS>/`-`: back parent dir" }

        local acts = picker_actions_list()
        if #acts > 0 then
            local labels = {}
            for _, it in ipairs(acts) do
                labels[#labels + 1] = ("%s: %s"):format(it.k, it.act)
            end
            parts[#parts + 1] = "[" .. table.concat(labels, ", ") .. "]"
        end

        return table.concat(parts, ", ")
    end

    local display_items = {}
    for _, c in ipairs(columns) do
        if c == "git" or c == "icon" then
            display_items[#display_items + 1] = { width = 2 }
        end
    end
    display_items[#display_items + 1] = { remaining = true }

    local displayer = t.entry_display.create({ separator = " ", items = display_items })

    local function file_icon(path, fallback_name)
        if devicons and devicons.get_icon then
            local filename = path and path:match("([^/\\]+)$") or (fallback_name .. ".md")
            local ext = filename:match("%.([^.]+)$") or ""
            return devicons.get_icon(filename, ext, { default = true }) or "󰈙"
        end
        return "󰈙"
    end

    local function icon_for(v)
        if v.kind == "back" then return "" end
        if v.kind == "folder" then return "" end
        return file_icon(v.path, v.name)
    end

    local function git_for(v)
        if v.kind == "back" then return "" end
        local label = v.git or "clean"

        if git_override then
            return git_symbols[label] or ""
        end

        return git_symbols[label] or git_symbols.unknown or ""
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

        t.pickers.new({}, {
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

                local function run_create()
                    t.actions.close(bufnr)
                    local prefix = stack_prefix(stack)
                    vim.schedule(function()
                        create_note_flexible(cwd, prefix, ask_ui, done)
                    end)
                end

                local function run_rename()
                    local v = selection()
                    if not v or v.kind == "back" then return end
                    t.actions.close(bufnr)
                    vim.schedule(function()
                        actions.rename(cwd, v, done)
                    end)
                end

                local function run_delete()
                    local v = selection()
                    if not v or v.kind == "back" then return end
                    t.actions.close(bufnr)
                    vim.schedule(function()
                        actions.delete(v, done)
                    end)
                end

                map("i", "<CR>", enter)
                map("n", "<CR>", enter)

                map("n", "<BS>", function() go_up(false) end)
                map("n", "-", function() go_up(true) end)
                map("i", "<C-h>", function() go_up(true) end)

                for _, it in ipairs(picker_actions_list()) do
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
    navigator(M._runtime_cfg())
end

--==============================================================
-- Commands
--==============================================================
local function create_commands()
    vim.api.nvim_create_user_command("Hematite", function(opts)
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

        vim.notify("[hematite] unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end, {
    nargs = "*",
    complete = function()
        return { "create", "rename", "delete", "vault", "daily" }
    end,
})
end

--==============================================================
-- Setup
--==============================================================
M.setup = function(user_opts)
    user_opts = user_opts or {}
    local incoming = vim.deepcopy(user_opts)

    -- Back-compat:
    -- If user passed old "keymaps" single-letter table, treat it as picker_actions.
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

    -- If old shape picker_actions = { c = { "create" } }, flatten it.
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

    local group = vim.api.nvim_create_augroup("HematiteFrontmatterUpdated", { clear = true })
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
