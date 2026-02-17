-- lua/hematite/init.lua

local M = {}

local function safe_require(mod)
    local ok, m = pcall(require, mod)
    return ok and m or nil
end

local scandir = safe_require("plenary.scandir")
local PlenaryPath = safe_require("plenary.path")
local Job = safe_require("plenary.job")

-- =========================
-- Path wrapper (nil-safe)
-- =========================
local function PathNew(p)
    if not p or p == "" then return nil end
    if not PlenaryPath then return nil end

    if type(PlenaryPath.new) == "function" then
        return PlenaryPath:new(p)
    end
    if type(PlenaryPath) == "function" then
        return PlenaryPath(p)
    end
    local ok, obj = pcall(function() return PlenaryPath(p) end)
    if ok then return obj end
    return nil
end

local function path_exists(p)
    local obj = PathNew(p)
    return obj and obj.exists and obj:exists() or false
end

local function path_parent_mkdir(p)
    local obj = PathNew(p)
    if not obj or not obj.parent or not obj.mkdir then return false end
    local parent = obj:parent()
    if not parent or not parent.mkdir then return false end
    parent:mkdir({ parents = true })
    return true
end

local function path_write_file(p, contents)
    local obj = PathNew(p)
    if not obj or not obj.write then return false end
    path_parent_mkdir(p)
    obj:write(contents, "w")
    return true
end

local function path_rm_file(p)
    local obj = PathNew(p)
    if not obj or not obj.exists or not obj.rm then return false end
    if obj:exists() then
        pcall(function() obj:rm() end)
        return true
    end
    return false
end

-- =========
-- Trash helpers
-- =========
local uv = vim.uv or vim.loop
local SYSNAME = (uv and uv.os_uname and uv.os_uname().sysname) or ""

local function is_exe(bin)
    return vim.fn.executable(bin) == 1
end

local function try_job(cmd, args)
    if not Job then return false end
    if not is_exe(cmd) then return false end

    local ok, j = pcall(function()
        return Job:new({ command = cmd, args = args })
    end)
    if not ok or not j then return false end

    local ok2 = pcall(function()
        j:sync()
    end)
    if not ok2 then return false end

    -- plenary.job sets j.code after :sync()
    return j.code == 0
end

-- Best-effort "trash" delete (macOS / Linux). Falls back to permanent delete.
local function path_trash_file(p)
    if not p or p == "" then return false end
    if not path_exists(p) then return false end

    -- macOS: Finder trash via osascript
    if SYSNAME == "Darwin" then
        local esc = (p:gsub("\\", "\\\\"):gsub('"', '\\"'))
        local script = 'tell application "Finder" to delete POSIX file "' .. esc .. '"'
        if try_job("osascript", { "-e", script }) then
            return true
        end
    end

    -- Linux / freedesktop trash (GNOME)
    if try_job("gio", { "trash", p }) then
        return true
    end

    -- trash-cli
    if try_job("trash-put", { p }) then
        return true
    end

    -- KDE
    if try_job("kioclient5", { "move", p, "trash:/" }) then
        return true
    end

    return path_rm_file(p)
end

local function path_rename(from, to)
    local fromp = PathNew(from)
    if not fromp or not fromp.rename then return false end
    path_parent_mkdir(to)
    fromp:rename({ new_name = to })
    return true
end

-- =========================
-- Config
-- =========================
M._config = {
    cwd = nil,
    exts = { "md", "markdown" },
    respect_gitignore = true,
    depth = nil,

    keymaps = {
        navigate = "<leader>nd",
    },

    -- Send deleted files to the trash instead of permanently deleting them
    delete_to_trash = true,

    -- inside the navigator
    use_default_keymaps = true,
    nav_keymaps = {
        ["c"] = { "create" },
        ["r"] = { "rename" },
        ["d"] = { "delete" },
    },

    -- UI columns left of name (order matters)
    -- supported: "git", "icon"
    columns = { "git", "icon" },
}

-- =========================
-- Helpers
-- =========================
local function now_ms()
    return math.floor(os.time() * 1000)
end

local function nanoid_like(len)
    len = len or 23
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = {}
    local seed = vim.loop.hrtime() % 2147483647
    math.randomseed(seed)
    for _ = 1, len do
        local idx = math.random(1, #alphabet)
        out[#out + 1] = alphabet:sub(idx, idx)
    end
    return table.concat(out)
end

local function title_from_note_name(note_full)
    local last = note_full:match("([^.]+)$") or note_full
    local s = (last or ""):gsub("[%-%_]+", " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "Untitled" end
    return s:sub(1, 1):upper() .. s:sub(2)
end

local function frontmatter_text(note_full, title, desc)
    local t = title or title_from_note_name(note_full)
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

local function write_file_if_missing(path, contents)
    if not path or path == "" then return false end
    if path_exists(path) then return false end
    return path_write_file(path, contents)
end

local function is_note_file(path, exts)
    local ext = path:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    for _, e in ipairs(exts) do
        if ext == e then return true end
    end
    return false
end

local function split_dots(name)
    local t = {}
    for seg in string.gmatch(name, "([^.]+)") do
        t[#t + 1] = seg
    end
    return t
end

local function node_has_children(node)
    return node and node.children and next(node.children) ~= nil
end

local function sorted_child_segments(node)
    local segs = {}
    for seg, _ in pairs(node.children or {}) do
        segs[#segs + 1] = seg
    end
    table.sort(segs)
    return segs
end

local function normalize_dir(p)
    if not p or p == "" then return nil end
    p = vim.fn.expand(p)
    if vim.fs and vim.fs.normalize then
        p = vim.fs.normalize(p)
    else
        p = p:gsub("\\", "/")
    end
    p = p:gsub("/+$", "")
    return p
end

-- =========================
-- Columns config normalization
-- =========================
-- Supports:
--  1) basic:    columns = { "git", "icon" }
--  2) advanced: columns = { git = { ...symbols... }, "icon" }
--  3) icons:    columns = { "icon" }
--  4) names:    columns = {}
local function normalize_columns(columns)
    if type(columns) ~= "table" then return {}, nil end

    local git_override = (type(columns.git) == "table") and columns.git or nil
    local out = {}
    local seen = {}

    -- If advanced git table is present, git is implicitly enabled at the front.
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

-- =========
-- Git status parsing + aggregation
-- =========

-- Convert porcelain XY to a semantic label (string key)
local function git_label_from_xy(xy)
    if not xy or xy == "" then return "clean" end
    if xy == "??" then return "untracked" end
    if xy == "!!" then return "ignored" end

    local x = xy:sub(1, 1)
    local y = xy:sub(2, 2)

    -- conflicts show up as U*/*U or AA/DD etc
    local conflict_pairs = {
        ["UU"]=true, ["AA"]=true, ["DD"]=true, ["AU"]=true, ["UA"]=true, ["DU"]=true, ["UD"]=true,
    }
    if conflict_pairs[xy] then return "conflicted" end

    -- prioritize index status first, then worktree
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

    return one(x) or one(y) or "clean"
end

-- folder should show "worst" status in subtree
local GIT_PRIORITY = {
    conflicted = 900,
    deleted    = 800,
    renamed    = 700,
    copied     = 650,
    added      = 600,
    modified   = 500,
    untracked  = 400,
    ignored    = 100,
    unknown    = 50,
    clean      = 0,
}

local function git_worst(a, b)
    a = a or "clean"
    b = b or "clean"
    return (GIT_PRIORITY[a] or 0) >= (GIT_PRIORITY[b] or 0) and a or b
end

-- Build abs-path -> git-label map for repo files under cwd (if cwd is inside a git repo)
local function build_git_status_map(cwd)
    if not (Job and cwd and cwd ~= "") then return nil end
    cwd = normalize_dir(cwd)
    if not cwd then return nil end

    -- Determine git repo root (top-level)
    local toplevel
    do
        local ok, res = pcall(function()
            return Job:new({
                command = "git",
                args = { "-C", cwd, "rev-parse", "--show-toplevel" },
            }):sync()
        end)
        if not ok or not res or not res[1] or res[1] == "" then
            return nil -- not a git repo (or git missing)
        end
        toplevel = normalize_dir(res[1])
        if not toplevel then return nil end
    end

    -- porcelain with NUL separators (safe for spaces)
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

    local i = 1
    local n = #blob

    local function read_until_nul(start_idx)
        local j = blob:find("\0", start_idx, true)
        if not j then
            -- no more NULs; stop safely
            return nil, n + 1
        end
        return blob:sub(start_idx, j - 1), j + 1
    end

    while i <= n do
        local rec
        rec, i = read_until_nul(i)
        if not rec then break end

        if #rec >= 4 then
            local xy = rec:sub(1, 2)
            local path = rec:sub(4)

            local x = xy:sub(1, 1)
            local y = xy:sub(2, 2)

            if x == "R" or y == "R" or x == "C" or y == "C" then
                local newpath
                newpath, i = read_until_nul(i)
                if newpath and newpath ~= "" then
                    path = newpath
                end
            end

            path = (path or ""):gsub("\\", "/")
            if path ~= "" then
                local label = git_label_from_xy(xy)
                -- IMPORTANT: paths are relative to repo root, not cwd
                local abs = toplevel .. "/" .. path
                abs = normalize_dir(abs) or abs
                result[abs] = label
            end
        end
    end

    return result
end

-- =========================
-- Tree build + git propagation
-- =========================
local function build_tree(files, git_map)
    local root = { seg = nil, full = "", children = {}, file = nil, git = "clean" }

    for _, item in ipairs(files) do
        local parts = split_dots(item.note)
        local node = root
        local acc = {}

        for _, seg in ipairs(parts) do
            acc[#acc + 1] = seg
            local child = node.children[seg]
            if not child then
                child = { seg = seg, full = table.concat(acc, "."), children = {}, file = nil, git = "clean" }
                node.children[seg] = child
            end
            node = child
        end

        node.file = item.path
        if git_map and item.path then
            node.git = git_map[item.path] or "clean"
        end
    end

    -- propagate worst status upward so folders show aggregate status
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

local function scan_notes_tree(cfg)
    if not (scandir and PlenaryPath) then
        vim.notify("[hematite] plenary.nvim is required", vim.log.levels.ERROR)
        return nil, nil, nil
    end

    local cwd = normalize_dir(cfg.cwd) or normalize_dir(vim.fn.getcwd())
    local exts = cfg.exts or { "md", "markdown" }
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
        if is_note_file(abs, exts) then
            local rel = abs
            local pobj = PathNew(abs)

            if pobj and pobj.make_relative then
                rel = pobj:make_relative(cwd)
            else
                local a = abs:gsub("\\", "/")
                local c = (cwd or ""):gsub("\\", "/"):gsub("/+$", "")
                if c ~= "" and a:sub(1, #c) == c then
                    rel = a:sub(#c + 2)
                else
                    rel = a
                end
            end

            rel = (rel or ""):gsub("\\", "/")
            local base = (rel:match("([^/]+)$") or rel):gsub("%.[^.]+$", "")
            local norm_abs = normalize_dir(abs) or abs
            files[#files + 1] = { path = norm_abs, note = base }
        end
    end

    return cwd, build_tree(files, git_map), git_map
end

-- =========
-- Prompt: returns "y", "n", or nil (cancel)
-- =========
local function prompt_ync(message)
    vim.cmd("redraw") -- clear any pending messages so we don't trigger hit-enter

    local ans = vim.fn.input(string.format("%s (y/n/c): ", message))
    ans = (ans or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if ans == "" or ans == "c" or ans == "cancel" then return nil end
    if ans == "y" or ans == "yes" then return "y" end
    if ans == "n" or ans == "no" then return "n" end

    -- unknown input => treat as cancel (safe)
    return nil
end

local function is_path_under(path, root)
    if not path or path == "" or not root or root == "" then return false end
    path = normalize_dir(path) or path:gsub("\\", "/")
    root = normalize_dir(root) or root:gsub("\\", "/"):gsub("/+$", "")
    return path:sub(1, #root) == root
end

local function update_frontmatter_updated(bufnr)
    bufnr = bufnr or 0
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines < 3 then return end
    if lines[1] ~= "---" then return end

    local fm_end
    for i = 2, math.min(#lines, 200) do
        if lines[i] == "---" then
            fm_end = i
            break
        end
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
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = vim.api.nvim_buf_get_name(b)
            local new = old_to_new[name]
            if new then
                vim.api.nvim_buf_set_name(b, new)
                vim.bo[b].modified = true
            end
        end
    end
end

local function ensure_unique_targets(pairs)
    local seen = {}
    for _, it in ipairs(pairs) do
        if it.to and seen[it.to] then
            return false, ("duplicate target path: %s"):format(it.to)
        end
        if it.to then seen[it.to] = true end
        if it.to and path_exists(it.to) then
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
        if it.from and it.to then path_rename(it.from, it.to) end
    end
end

local function wipe_buffers_for_paths(paths)
    local lookup = {}
    for _, p in ipairs(paths) do if p then lookup[p] = true end end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = normalize_dir(vim.api.nvim_buf_get_name(b)) or vim.api.nvim_buf_get_name(b)
            if lookup[name] then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
    end
end

local function locate_node(root, segments)
    local node = root
    for _, seg in ipairs(segments) do
        if not node.children or not node.children[seg] then
            return root
        end
        node = node.children[seg]
    end
    return node
end

local function stack_to_prefix(stack)
    if #stack == 0 then return "" end
    return table.concat(stack, ".")
end

-- =========================
-- Telescope deps
-- =========================
local function telescope_deps()
    local pickers = safe_require("telescope.pickers")
    local finders = safe_require("telescope.finders")
    local conf = safe_require("telescope.config") and require("telescope.config").values or nil
    local entry_display = safe_require("telescope.pickers.entry_display")
    local actions = safe_require("telescope.actions")
    local action_state = safe_require("telescope.actions.state")
    local previewers = safe_require("telescope.previewers")
    if not (pickers and finders and conf and entry_display and actions and action_state) then
        return nil
    end
    return {
        pickers = pickers,
        finders = finders,
        conf = conf,
        entry_display = entry_display,
        actions = actions,
        action_state = action_state,
        previewers = previewers,
    }
end

local function safe_previewer(t)
  if not t or not t.previewers then return nil end
  local p = t.previewers
  local utils = safe_require("telescope.previewers.utils")

  -- 1) Best case: Telescope's built-in buffer previewer (already does ft + highlighting)
  if p.vim_buffer_cat and type(p.vim_buffer_cat.new) == "function" then
    local ok, res = pcall(function()
      return p.vim_buffer_cat.new({})
    end)
    if ok and res then return res end
  end

  -- 2) Fallback: custom buffer previewer with same UX guarantees
  if p.new_buffer_previewer then
    local ok, res = pcall(function()
      return p.new_buffer_previewer({
        define_preview = function(self, entry, status)
          local path = entry and entry.value and entry.value.path
          if not path or path == "" then return end

          local bufnr = self.state.bufnr
          local winid = (status and (status.preview_win or status.preview_winid)) or self.state.winid

          -- Read + write content
          local lines = vim.fn.readfile(path, "", 200)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

          -- Filetype + highlighting (only if path/ft changed)
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

          -- Ensure top-aligned preview (only when selection/file changed)
          if self.state._hematite_last_path ~= path then
            self.state._hematite_last_path = path
            if winid and vim.api.nvim_win_is_valid(winid) then
              vim.schedule(function()
                if vim.api.nvim_win_is_valid(winid) then
                  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
                  vim.api.nvim_win_call(winid, function()
                    vim.cmd("normal! zt")
                  end)
                end
              end)
            end
          end
        end,
      })
    end)
    if ok and res then return res end
  end

  -- 3) Last resort: terminal cat previewer (may bottom-align)
  if p.cat and type(p.cat.new) == "function" then
    local ok, res = pcall(function() return p.cat.new({}) end)
    if ok and res then return res end
  end

  return nil
end

-- =========================
-- Navigator (single picker)
-- =========================
local function navigator(cfg)
    local t = telescope_deps()
    if not t then
        vim.notify("[hematite] telescope.nvim is required", vim.log.levels.ERROR)
        return
    end

    local devicons = safe_require("nvim-web-devicons")

    local col_list, git_override = normalize_columns(cfg.columns or M._config.columns or {})
    local columns = col_list
    local git_symbols = git_override or (M._config.git_symbols or {})

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
        local prefix = stack_to_prefix(stack)
        return (prefix == "") and "Hematite" or ("Hematite: " .. prefix)
    end

    local function results_title()
        local base = "Enter: enter/open   <BS>/`-`: back parent dir"
        if M._config.use_default_keymaps == false then
            return base
        end
        return base .. "   c/r/d: create/rename/delete"
    end

    -- Build entry_display columns dynamically
    local display_items = {}
    for _, c in ipairs(columns) do
        if c == "git" then
            display_items[#display_items + 1] = { width = 2 }
        elseif c == "icon" then
            display_items[#display_items + 1] = { width = 2 }
        end
    end
    display_items[#display_items + 1] = { remaining = true }

    local displayer = t.entry_display.create({
        separator = " ",
        items = display_items,
    })

    local function file_icon(path, fallback_name)
        if devicons and devicons.get_icon then
            local filename = path and path:match("([^/\\]+)$") or (fallback_name .. ".md")
            local ext = filename:match("%.([^.]+)$") or ""
            return devicons.get_icon(filename, ext, { default = true }) or "󰈙"
        end
        return "󰈙"
    end

    local function icon_for_entry(v)
        if v.kind == "back" then return "" end
        if v.kind == "folder" then return "" end
        return file_icon(v.path, v.name)
    end

    local function git_for_entry(v)
        if v.kind == "back" then return "" end
        local label = v.git or "clean"
        return git_symbols[label] or git_symbols.unknown or "~ "
    end

    local function make_display(v)
        local cols = {}

        for _, c in ipairs(columns) do
            if c == "git" then
                cols[#cols + 1] = { git_for_entry(v) }
            elseif c == "icon" then
                cols[#cols + 1] = { icon_for_entry(v) }
            end
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
                local p = item.path
                if type(p) ~= "string" then p = "" end

                return {
                    value = item,
                    ordinal = item.full or item.name,
                    display = function(e) return make_display(e.value) end,
                    path = p,
                    filename = p,
                }
            end
        })
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

    local function create_here()
        local parent_prefix = stack_to_prefix(stack)
        vim.ui.input({ prompt = "New note name (segment; '-' concept, '.' hierarchy): " }, function(segment)
            if not segment or segment:gsub("%s+", "") == "" then return end
            segment = segment:gsub("^%s+", ""):gsub("%s+$", "")
            local note_full = (parent_prefix ~= "") and (parent_prefix .. "." .. segment) or segment

            vim.ui.input({ prompt = "Title (optional): ", default = title_from_note_name(note_full) }, function(title)
                title = (title and title:gsub("^%s+", ""):gsub("%s+$", "")) or ""
                if title == "" then title = title_from_note_name(note_full) end

                vim.ui.input({ prompt = "Desc (optional): ", default = "" }, function(desc)
                    desc = desc or ""
                    local path = cwd .. "/" .. note_full .. ".md"
                    write_file_if_missing(path, frontmatter_text(note_full, title, desc))
                    vim.cmd("edit " .. vim.fn.fnameescape(path))
                end)
            end)
        end)
    end

    local function delete_target(v)
        local function delete_one(path)
            if not path or path == "" then return false end
            if M._config.delete_to_trash then
                return path_trash_file(path)
            end
            return path_rm_file(path)
        end

        local function verb()
            return (M._config.delete_to_trash and "trashed") or "deleted"
        end

        if v.kind == "folder" then
            local paths = gather_files_under(v.node)
            if #paths == 0 then
                vim.notify("[hematite] folder has no note files", vim.log.levels.WARN)
                return false
            end
            local ans = prompt_ync(("Delete folder '%s' and %d note(s)?"):format(v.full or v.name, #paths))
            if ans ~= "y" then return false end

            wipe_buffers_for_paths(paths)
            for _, p in ipairs(paths) do if p then delete_one(p) end end
            vim.notify(("[hematite] %s %d file(s)"):format(verb(), #paths), vim.log.levels.INFO)
            return true
        end

        if not v.path then
            vim.notify("[hematite] no file exists for this node", vim.log.levels.WARN)
            return false
        end

        local ans = prompt_ync(("Delete note '%s'?"):format(v.full or v.name))
        if ans ~= "y" then return false end

        wipe_buffers_for_paths({ v.path })
        delete_one(v.path)
        vim.notify(("[hematite] %s 1 file"):format(verb()), vim.log.levels.INFO)
        return true
    end

    local function rename_target(v)
        if v.kind == "folder" then
            local old_prefix = v.full or v.name
            vim.ui.input({
                prompt = ("Rename folder '%s' to (full prefix): "):format(old_prefix),
                default = old_prefix,
            }, function(new_prefix)
                if not new_prefix or new_prefix:gsub("%s+", "") == "" then return end
                new_prefix = new_prefix:gsub("^%s+", ""):gsub("%s+$", "")

                local items = gather_note_files_with_full(v.node)
                if #items == 0 then
                    vim.notify("[hematite] folder has no note files to rename", vim.log.levels.WARN)
                    return
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
                    return
                end

                do_batch_rename(pairs)
                vim.notify(("[hematite] renamed folder '%s' -> '%s' (%d files)"):format(old_prefix, new_prefix, #pairs), vim.log.levels.INFO)
            end)
            return true
        end

        if not v.path then
            vim.notify("[hematite] no file exists for this node", vim.log.levels.WARN)
            return false
        end

        local old_full = v.full or v.name
        vim.ui.input({
            prompt = ("Rename '%s' to (full name): "):format(old_full),
            default = old_full,
        }, function(new_full)
            if not new_full or new_full:gsub("%s+", "") == "" then return end
            new_full = new_full:gsub("^%s+", ""):gsub("%s+$", "")

            local pairs = { { from = v.path, to = cwd .. "/" .. new_full .. ".md" } }
            local ok, err = ensure_unique_targets(pairs)
            if not ok then
                vim.notify("[hematite] rename aborted: " .. err, vim.log.levels.ERROR)
                return
            end

            do_batch_rename(pairs)
            vim.notify(("[hematite] renamed '%s' -> '%s'"):format(old_full, new_full), vim.log.levels.INFO)
        end)
        return true
    end

    local function get_nav_keymaps()
        if M._config.use_default_keymaps == false then return {} end
        return M._config.nav_keymaps or {}
    end

    local function open_picker()
        local node = current_node()
        local nav_keymaps = get_nav_keymaps()

        t.pickers.new({}, {
            prompt_title = title_for(),
            results_title = results_title(),
            finder = make_finder(node),
            sorter = t.conf.generic_sorter({}),
            previewer = safe_previewer(t),
            attach_mappings = function(bufnr, map)
                local picker = t.action_state.get_current_picker(bufnr)

                local function refresh_in_place(reset_prompt)
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
                    refresh_in_place(true)
                end

                local function enter()
                    local sel = t.action_state.get_selected_entry()
                    if not sel or not sel.value then return end
                    local v = sel.value

                    if v.kind == "folder" then
                        stack[#stack + 1] = v.name
                        refresh_in_place(true)
                        return
                    end

                    t.actions.close(bufnr)
                    if v.path then
                        vim.schedule(function()
                            vim.cmd("edit " .. vim.fn.fnameescape(v.path))
                        end)
                    end
                end

                local function current_selection()
                    local sel = t.action_state.get_selected_entry()
                    return sel and sel.value or nil
                end

                local function run_create()
                    t.actions.close(bufnr)
                    vim.schedule(function()
                        create_here()
                    end)
                end

                local function run_rename()
                    local v = current_selection()
                    if not v or v.kind == "back" then return end
                    t.actions.close(bufnr)
                    vim.schedule(function()
                        local changed = rename_target(v)
                        if changed then rescan() end
                        open_picker()
                    end)
                end

                local function run_delete()
                    local v = current_selection()
                    if not v or v.kind == "back" then return end
                    t.actions.close(bufnr)
                    vim.schedule(function()
                        local changed = delete_target(v)
                        if changed then rescan() end
                        open_picker()
                    end)
                end

                map("i", "<CR>", enter)
                map("n", "<CR>", enter)

                map("n", "<BS>", function() go_up(false) end)
                map("n", "-", function() go_up(true) end)

                map("i", "<C-h>", function() go_up(true) end)

                -- configurable navigator actions
                for key, actions_list in pairs(nav_keymaps) do
                    if type(key) == "string" and #key == 1 and type(actions_list) == "table" then
                        map("n", key, function()
                            local act = actions_list[1]
                            if act == "create" then
                                run_create()
                            elseif act == "rename" then
                                run_rename()
                            elseif act == "delete" then
                                run_delete()
                            end
                        end)
                    end
                end

                return true
            end,
        }):find()
    end

    open_picker()
end

-- =========================
-- Public API
-- =========================
function M.navigate()
    navigator(M._runtime_cfg())
end

function M._runtime_cfg()
    local cfg = M._config
    return {
        cwd = normalize_dir(cfg.cwd) or normalize_dir(vim.fn.getcwd()),
        exts = cfg.exts,
        respect_gitignore = cfg.respect_gitignore,
        depth = cfg.depth,
        columns = cfg.columns,
    }
end

-- =========================
-- User Commands
-- =========================
local function create_commands()
    vim.api.nvim_create_user_command("Hematite", function() M.navigate() end, {})
end

-- =========================
-- Setup
-- =========================
M.setup = function(user_opts)
    user_opts = user_opts or {}
    local incoming = vim.deepcopy(user_opts)

    -- Default git symbols are defined in setup (not in base config).
    local DEFAULT_GIT_SYMBOLS = {
        clean      = "  ",
        modified   = "M ",
        added      = "A ",
        deleted    = "D ",
        renamed    = "R ",
        copied     = "C ",
        untracked  = "? ",
        ignored    = "! ",
        conflicted = "U ",
        unknown    = "~ ",
    }

    -- Accept the requested shape:
    -- require("hematite").setup({
    --   keymaps = { ["c"] = { "create" }, ["d"] = { "delete" }, ["r"] = { "rename" } },
    --   use_default_keymaps = true,
    -- })
    -- If keymaps are single-letter keys, treat them as nav_keymaps, not leader mappings.
    if type(incoming.keymaps) == "table" then
        local looks_like_nav = false
        for k, v in pairs(incoming.keymaps) do
            if type(k) == "string" and #k == 1 and type(v) == "table" then
                looks_like_nav = true
                break
            end
        end
        if looks_like_nav then
            incoming.nav_keymaps = incoming.keymaps
            incoming.keymaps = nil
        end
    end

    M._config = vim.tbl_deep_extend("force", M._config, incoming)
    M._config.cwd = normalize_dir(M._config.cwd)

    -- Ensure base (fallback) git symbols exist. Advanced columns.git can still override at runtime.
    if type(M._config.git_symbols) ~= "table" then
        M._config.git_symbols = DEFAULT_GIT_SYMBOLS
    end

    create_commands()

    -- leader keymap: only navigate
    local km = M._config.keymaps or {}
    if km.navigate and km.navigate ~= "" then
        vim.keymap.set("n", km.navigate, "<cmd>Hematite<cr>", { desc = "Hematite: navigate" })
    end

    -- autoupdate updated: on save
    local group = vim.api.nvim_create_augroup("HematiteFrontmatterUpdated", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
        group = group,
        pattern = { "*.md", "*.markdown" },
        callback = function(ev)
            local root = normalize_dir(M._config.cwd) or normalize_dir(vim.fn.getcwd())
            local file = ev.match or vim.api.nvim_buf_get_name(ev.buf)
            if not is_path_under(file, root) then return end
            update_frontmatter_updated(ev.buf)
        end,
        desc = "Update Dendron-style frontmatter 'updated' timestamp",
    })
end

return M
