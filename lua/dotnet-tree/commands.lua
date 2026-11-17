local cc = require("neo-tree.sources.common.commands")
local reveal = require("dotnet-tree.reveal")
local terminal = require("dotnet-tree.terminal")

local M = {}
-- neo-tree's common commands, for its default keys (selection, preview,
-- closing the window...). Those that act on files read a node's id or path as
-- a file, which here it may not be: the file operations, their visual forms,
-- the trash and the open commands are redefined below.
for k, v in pairs(cc) do
  M[k] = v
end

local NON_OPENABLE = {
  package = true,
  framework = true,
  packages = true,
  frameworks = true,
  projrefs = true,
  dependencies = true,
  sln_folder = true,
  solution = true,
}

function M.show_help(state)
  local mappings = state.window and state.window.mappings or {}
  local dotnet, files, other = {}, {}, {}

  for key, val in pairs(mappings) do
    local cmd, desc
    if type(val) == "table" then
      cmd, desc = val[1], val.desc
    elseif type(val) == "string" then
      cmd, desc = val, val
    elseif type(val) == "function" then
      cmd, desc = "<lua>", "<lua function>"
    end
    if cmd and cmd ~= "noop" and cmd ~= "none" then
      desc = desc or cmd
      local label = desc:match("^%[%.NET%]%s*(.+)$")
      local file_label = desc:match("^%[file%]%s*(.+)$")
      if label then
        table.insert(dotnet, { key = key, desc = label })
      elseif file_label then
        table.insert(files, { key = key, desc = file_label })
      else
        table.insert(other, { key = key, desc = desc })
      end
    end
  end

  local function sort(t)
    table.sort(t, function(a, b)
      return a.key:lower() < b.key:lower()
    end)
  end
  sort(dotnet)
  sort(files)
  sort(other)

  local lines = {}
  local function add_section(title, items)
    if #items == 0 then
      return
    end
    table.insert(lines, title)
    for _, m in ipairs(items) do
      table.insert(lines, string.format("  %-16s %s", m.key, m.desc))
    end
    table.insert(lines, "")
  end

  add_section("─── Files ───", files)
  add_section("─── .NET ───", dotnet)
  add_section("─── Navigation ───", other)
  if lines[#lines] == "" then
    table.remove(lines)
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(width + 2, 36)
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " dotnet-tree help ",
    title_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<esc>", close, { buffer = buf, nowait = true, silent = true })
end

function M.refresh(state)
  require("dotnet-tree").navigate(state)
end

function M.open(state)
  local node = state.tree:get_node()
  if not node then
    return
  end
  local kind = node.extra and node.extra.kind

  if NON_OPENABLE[kind] or node.type == "directory" then
    if node:has_children() then
      reveal.forget(state, node:get_id())
      cc.toggle_node(state)
    end
    return
  end

  if kind == "project_reference" or kind == "project" then
    if node.path then
      cc.open(state)
    end
    return
  end

  if node.path then
    cc.open(state)
  end
end

function M.select_solution(state)
  local cwd = state.path or vim.fn.getcwd()
  local slns = require("dotnet-tree.parser.solution").find(cwd)
  if #slns == 0 then
    vim.notify("[dotnet-tree] no .sln/.slnx found", vim.log.levels.WARN)
    return
  end
  if #slns == 1 then
    state.dotnet_sln = slns[1]
    require("dotnet-tree.store").set(state.path or vim.fn.getcwd(), slns[1])
    require("dotnet-tree").navigate(state)
    return
  end
  vim.ui.select(slns, { prompt = "Select solution:" }, function(choice)
    if not choice then
      return
    end
    state.dotnet_sln = choice
    require("dotnet-tree.store").set(state.path or vim.fn.getcwd(), choice)
    require("dotnet-tree").navigate(state)
  end)
end

-- A directory the user toggles is theirs from then on: follow_current_file
-- must not close it again (reveal.forget).
local function current_id(state)
  local node = state.tree and state.tree:get_node()
  return node and node:get_id()
end

function M.toggle_node(state)
  reveal.forget(state, current_id(state))
  cc.toggle_node(state)
end

function M.close_node(state)
  reveal.forget(state, current_id(state))
  cc.close_node(state)
end

function M.close_all_nodes(state)
  reveal.forget(state)
  cc.close_all_nodes(state)
end

function M.expand_all_nodes(state)
  reveal.forget(state)
  cc.expand_all_nodes(state)
end

local function find_project_node(state)
  local node = state.tree:get_node()
  while node do
    if node.extra and node.extra.kind == "project" then
      return node
    end
    local parent_id = node:get_parent_id()
    if not parent_id then
      return nil
    end
    node = state.tree:get_node(parent_id)
  end
  return nil
end

local function add_package(csproj_path)
  vim.ui.input({ prompt = "Package name (optional @version): " }, function(input)
    if not input or input == "" then
      return
    end
    local name, version = input:match("^([^@%s]+)@(.+)$")
    name = name or input
    local cmd = "dotnet add " .. vim.fn.shellescape(csproj_path) .. " package " .. vim.fn.shellescape(name)
    if version then
      cmd = cmd .. " --version " .. vim.fn.shellescape(version)
    end
    terminal.open(cmd, "add " .. name .. " to " .. terminal.project_name(csproj_path))
  end)
end

local function add_reference(state, csproj_path)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  local sln = require("dotnet-tree.parser.solution").parse(state.dotnet_sln)
  if not sln then
    return
  end
  local options = {}
  for _, proj in ipairs(sln.projects) do
    if proj.path and proj.path ~= csproj_path and proj.kind ~= "folder" then
      table.insert(options, proj)
    end
  end
  if #options == 0 then
    vim.notify("[dotnet-tree] no other projects in solution", vim.log.levels.WARN)
    return
  end
  vim.ui.select(options, {
    prompt = "Select project to reference:",
    format_item = function(p)
      return p.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    local cmd = "dotnet add " .. vim.fn.shellescape(csproj_path) .. " reference " .. vim.fn.shellescape(choice.path)
    terminal.open(cmd, "add " .. choice.name .. " to " .. terminal.project_name(csproj_path))
  end)
end

-- ─── solution folders (#66) ────────────────────────────────────────────────

-- The solution, or the solution folder `n` and `a` act on: the folder under the
-- cursor, or the one a solution item under the cursor is listed in.
---@return table|nil { guid = folder guid or nil for the solution itself }
local function solution_target(state)
  local node = state.tree:get_node()
  local extra = node and node.extra or {}
  if extra.kind == "solution" then
    return {}
  elseif extra.kind == "sln_folder" then
    return { guid = extra.guid }
  elseif extra.kind == "file" and extra.sln_folder then
    return { guid = extra.sln_folder }
  end
end

local function warn(message)
  vim.notify("[dotnet-tree] " .. message, vim.log.levels.WARN)
end

local function info(message)
  vim.notify("[dotnet-tree] " .. message, vim.log.levels.INFO)
end

-- The solution as it is on disk now, and the folder `guid` in it
local function load_solution(state, guid)
  if not state.dotnet_sln then
    warn("no solution loaded")
    return nil
  end
  local solution = require("dotnet-tree.parser.solution")
  solution.invalidate(state.dotnet_sln)
  local sln, err = solution.parse(state.dotnet_sln)
  if not sln then
    warn("could not read the solution: " .. tostring(err))
    return nil
  end
  local folder = guid and sln.by_guid[guid]
  if guid and not folder then
    warn("that solution folder is no longer in the solution file; press R")
    return nil
  end
  return sln, folder
end

-- Names of the folders directly under `folder`, or at the root
local function folder_names(sln, folder)
  local names = {}
  for _, entry in ipairs(sln.projects) do
    if entry.kind == "folder" and entry.parent_guid == (folder and folder.guid or nil) then
      table.insert(names, entry.name)
    end
  end
  return names
end

-- Build the tree again from the file and, when the node `id` is found, put the
-- cursor on it. A failure is reported, never swallowed.
local function show(state, id)
  local ok, err = pcall(function()
    require("neo-tree.sources.manager").navigate(state, state.path, nil, function()
      local focused, focus_err = pcall(require("dotnet-tree.reveal").focus, state, id)
      if not focused then
        warn("could not put the cursor on the new node: " .. tostring(focus_err))
      end
    end)
  end)
  if not ok then
    warn("could not redraw the tree, rebuilding it: " .. tostring(err))
    require("dotnet-tree.refresh").rebuild()
  end
end

local function folder_id(sln_path, id)
  local is_slnx = sln_path:lower():match("%.slnx$") ~= nil
  return "dotnet:slnfolder:" .. (is_slnx and ("slnxfolder:" .. id) or id)
end

local function new_solution_folder(state, sln, parent)
  local where = parent and parent.name or vim.fn.fnamemodify(state.dotnet_sln, ":t")
  vim.ui.input({ prompt = ("New solution folder in %s: "):format(where) }, function(name)
    if not name then
      return
    end
    local ok, err, id =
      require("dotnet-tree.solution_edit").add_folder(state.dotnet_sln, parent, name, folder_names(sln, parent))
    if not ok then
      warn(err)
      return
    end
    info(("created solution folder %s in %s"):format(vim.trim(name), where))
    show(state, folder_id(state.dotnet_sln, id))
  end)
end

-- Ask for a path, starting in the folder's directory on disk, with completion.
-- `cb` gets the absolute path, and whether the answer named a directory (it
-- ended in a slash, which normalizing would drop).
local function ask_path(prompt, sln, folder, cb)
  local dir = require("dotnet-tree.solution_edit").directory(sln, folder)
  local default = vim.fn.fnamemodify(dir, ":~:.")
  if default ~= "" and default:sub(-1) ~= "/" then
    default = default .. "/"
  end
  vim.ui.input({ prompt = prompt, default = default, completion = "file" }, function(input)
    if not input then
      return
    end
    input = vim.trim(input)
    if input == "" then
      warn("no path given")
      return
    end
    local is_dir = input:sub(-1) == "/" or input:sub(-1) == "\\"
    cb(vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(input), ":p")), is_dir)
  end)
end

local function add_to_folder(state, folder, path)
  local edit = require("dotnet-tree.solution_edit")
  local ok, err = edit.add_file(state.dotnet_sln, folder, path)
  if not ok then
    warn(err)
    return false
  end
  info(("added %s to %s"):format(vim.fn.fnamemodify(path, ":~:."), folder.name))
  -- The node id is built from the path as the parser reads it back
  local sln, fresh = load_solution(state, folder.guid)
  local item = sln and edit.item_path(fresh, path) or path
  show(state, "dotnet:slnitem:" .. folder.guid .. ":" .. item)
  return true
end

-- The directories `mkdir -p` would create for `dir`, outermost first
local function missing_dirs(dir)
  local missing = {}
  while dir ~= "" and vim.fn.isdirectory(dir) == 0 do
    table.insert(missing, 1, dir)
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return missing
end

-- Remove the file and the directories created for it, innermost first
local function undo_create(path, created)
  local removed, err = os.remove(path)
  if not removed then
    warn(("could not remove %s after the failed add: %s"):format(vim.fn.fnamemodify(path, ":~:."), err))
    return
  end
  for i = #created, 1, -1 do
    vim.uv.fs_rmdir(created[i])
  end
end

-- In an editor window, as `<cr>` opens a file, never in the tree's
local function open_in_editor(state, path)
  local ok, err = pcall(require("neo-tree.utils").open_file, state, path)
  if ok then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype ~= "neo-tree" and vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_set_current_win(win)
      local edited, edit_err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
      if not edited then
        warn(("could not open %s: %s"):format(vim.fn.fnamemodify(path, ":~:."), edit_err))
      end
      return
    end
  end
  warn(("could not open %s: %s"):format(vim.fn.fnamemodify(path, ":~:."), err))
end

local function new_solution_item(state, sln, folder)
  ask_path(("New file in %s: "):format(folder.name), sln, folder, function(path, is_dir)
    if is_dir or vim.fn.isdirectory(path) == 1 then
      warn("give the file a name, after the directory")
      return
    end
    if vim.uv.fs_stat(path) then
      warn(("%s already exists: press `a` to add it to %s"):format(vim.fn.fnamemodify(path, ":~:."), folder.name))
      return
    end
    local created = missing_dirs(vim.fn.fnamemodify(path, ":h"))
    local made, err = pcall(function()
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      vim.fn.writefile({}, path)
    end)
    if not made then
      warn(("could not create %s: %s"):format(vim.fn.fnamemodify(path, ":~:."), err))
      for i = #created, 1, -1 do
        vim.uv.fs_rmdir(created[i])
      end
      return
    end
    if not add_to_folder(state, folder, path) then
      -- Not in the solution: leave nothing behind
      undo_create(path, created)
      return
    end
    open_in_editor(state, path)
  end)
end

--- `n` on the solution or a solution folder.
local function solution_new(state, target)
  local sln, folder = load_solution(state, target.guid)
  if not sln then
    return
  end
  if not folder then
    new_solution_folder(state, sln, nil)
    return
  end
  vim.ui.select({ "file", "solution folder" }, { prompt = ("New in %s:"):format(folder.name) }, function(choice)
    if choice == "file" then
      new_solution_item(state, sln, folder)
    elseif choice == "solution folder" then
      new_solution_folder(state, sln, folder)
    end
  end)
end

--- `a` on a solution folder: add a file that exists.
local function solution_add(state, target)
  local sln, folder = load_solution(state, target.guid)
  if not sln then
    return
  end
  ask_path(("Add file to %s: "):format(folder.name), sln, folder, function(path)
    if vim.fn.isdirectory(path) == 1 then
      warn(("%s is a directory: name a file in it"):format(vim.fn.fnamemodify(path, ":~:.")))
      return
    end
    if vim.fn.filereadable(path) == 0 then
      warn(("no file at %s"):format(vim.fn.fnamemodify(path, ":~:.")))
      return
    end
    add_to_folder(state, folder, path)
  end)
end

--- `,a`: a package or a project reference, to the project under the cursor.
function M.add_package_or_reference(state)
  local node = state.tree:get_node()
  if not node then
    return
  end
  local proj_node = find_project_node(state)
  if not proj_node or not proj_node.extra.project or not proj_node.extra.project.path then
    vim.notify("[dotnet-tree] not in a project", vim.log.levels.WARN)
    return
  end
  local csproj_path = proj_node.extra.project.path
  local kind = node.extra and node.extra.kind

  -- nuget.nvim, when installed, does packages better than a name prompt: search, versions,
  -- and the package's state across the solution
  local function packages(on_kind)
    local handled = require("dotnet-tree.nuget").open(on_kind, {
      project = csproj_path,
      solution = state.dotnet_sln,
      package = on_kind == "package" and node.extra.package and node.extra.package.name or nil,
    })
    if not handled then
      add_package(csproj_path)
    end
  end

  if kind == "packages" or kind == "package" then
    packages(kind)
  elseif kind == "projrefs" or kind == "project_reference" then
    add_reference(state, csproj_path)
  else
    vim.ui.select({ "package", "reference" }, { prompt = "Add to " .. proj_node.name .. ":" }, function(choice)
      if choice == "package" then
        packages("packages")
      elseif choice == "reference" then
        add_reference(state, csproj_path)
      end
    end)
  end
end

local TEMPLATES = {
  class = "namespace %s;\n\npublic class %s\n{\n}\n",
  interface = "namespace %s;\n\npublic interface %s\n{\n}\n",
  record = "namespace %s;\n\npublic record %s();\n",
  struct = "namespace %s;\n\npublic struct %s\n{\n}\n",
  enum = "namespace %s;\n\npublic enum %s\n{\n}\n",
}

local function compute_target_dir(state, proj_node)
  local node = state.tree:get_node()
  if node then
    local kind = node.extra and node.extra.kind
    if kind == "folder" and node.path then
      return node.path
    elseif kind == "file" and node.path then
      return vim.fn.fnamemodify(node.path, ":h")
    end
  end
  if proj_node.extra and proj_node.extra.project and proj_node.extra.project.path then
    return vim.fn.fnamemodify(proj_node.extra.project.path, ":h")
  end
end

function M.new_file(state)
  local target = solution_target(state)
  if target then
    solution_new(state, target)
    return
  end
  local proj_node = find_project_node(state)
  if not proj_node or not proj_node.extra.project or not proj_node.extra.project.path then
    vim.notify("[dotnet-tree] not in a project", vim.log.levels.WARN)
    return
  end
  local target_dir = compute_target_dir(state, proj_node)
  if not target_dir then
    return
  end

  local types = { "class", "interface", "record", "struct", "enum" }
  vim.ui.select(types, { prompt = "Type:" }, function(typ)
    if not typ then
      return
    end
    vim.ui.input({ prompt = typ .. " name: " }, function(input)
      if not input or input == "" then
        return
      end
      local name = input:gsub("%.cs$", "")
      if typ == "interface" and not name:match("^I[%u]") then
        name = "I" .. name
      end
      local ns = require("dotnet-tree.namespace").for_dir(proj_node.extra.project.path, target_dir)
      local content = string.format(TEMPLATES[typ], ns, name)
      local target_path = target_dir .. "/" .. name .. ".cs"

      if vim.fn.filereadable(target_path) == 1 then
        vim.notify("[dotnet-tree] already exists: " .. target_path, vim.log.levels.WARN)
        return
      end

      vim.fn.mkdir(target_dir, "p")
      local lines = {}
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      if lines[#lines] == "" then
        table.remove(lines)
      end
      vim.fn.writefile(lines, target_path)
      vim.cmd("edit " .. vim.fn.fnameescape(target_path))
      pcall(function()
        require("neo-tree.sources.manager").refresh("dotnet-tree")
      end)
    end)
  end)
end

function M.edit_project_file(state)
  local node = find_project_node(state)
  if not node or not node.extra.project or not node.extra.project.path then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(node.extra.project.path))
end

-- build and clean go to the quickfix list; run, test and watch stay in the
-- terminal, where their output is interactive. See dotnet-tree/build.lua.
local function run_build(action, path)
  require("dotnet-tree.build").build(path, { action = action })
end

function M.build(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_build("build", node.extra.project.path)
end

-- `,r`, `,t` and `,w` start in the project's folder, not in Neovim's: a function
-- app's host is found relative to it (#57), and the default host of an
-- ASP.NET Core app reads appsettings.json from its working directory.
local function project_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

local FUNC_INSTALL = "https://learn.microsoft.com/azure/azure-functions/functions-run-local"

-- What starting the project at `path` with `,r` (`watch` false) or `,w` → run
-- (`watch` true) needs when it is an Azure Functions app (#57): `func` on
-- PATH, and Azurite when the app uses it, which is checked in the background
-- and only warned about. `dotnet watch` cannot start the host of an app that
-- `dotnet run` cannot start either, so `,w` refuses those and points to `,r`.
-- Returns whether to go on, and the function app, nil for any other project.
-- A refusal has been reported.
local function prepare_function_app(path, watch)
  local functions = require("dotnet-tree.functions")
  local fn_app = functions.detect(path)
  if not fn_app then
    return true, nil
  end
  local name = terminal.project_name(path)
  if vim.fn.executable("func") == 0 then
    vim.notify(
      ("[dotnet-tree] %s is an Azure Functions app and needs Azure Functions Core Tools (`func`) on PATH: %s"):format(
        name,
        FUNC_INSTALL
      ),
      vim.log.levels.ERROR
    )
    return false, fn_app
  end
  if watch and fn_app.func then
    local msg = "[dotnet-tree] dotnet watch cannot start %s: an in-process or Worker SDK 1.x function app "
      .. "runs with `func start`. Press `,r` instead."
    vim.notify(msg:format(name), vim.log.levels.ERROR)
    return false, fn_app
  end
  functions.warn_without_azurite(fn_app.dir, name)
  return true, fn_app
end

function M.run_project(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  local path = node.extra.project.path
  local go, fn_app = prepare_function_app(path, false)
  if not go then
    return
  end
  -- `func start` runs the Functions host, which reads no launch profile
  if fn_app and fn_app.func then
    terminal.open("func start", "run " .. terminal.project_name(path), project_dir(path))
    return
  end
  local launch_profile = require("dotnet-tree.launch_profile")
  launch_profile.choose(path, function(profile)
    terminal.open(
      "dotnet run --project " .. vim.fn.shellescape(path) .. launch_profile.args(profile),
      "run " .. terminal.project_name(path),
      project_dir(path)
    )
  end)
end

function M.build_solution(state)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  run_build("build", state.dotnet_sln)
end

function M.clean(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_build("clean", node.extra.project.path)
end

function M.clean_solution(state)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  run_build("clean", state.dotnet_sln)
end

function M.test(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  local path = node.extra.project.path
  terminal.open("dotnet test " .. vim.fn.shellescape(path), "test " .. terminal.project_name(path), project_dir(path))
end

-- `,d`: build the project under the cursor, then start netcoredbg on what it
-- built. Both nvim-dap and netcoredbg are optional; dotnet-tree/debug.lua says
-- so rather than raising when they are missing.
function M.debug(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  require("dotnet-tree.debug").debug(node.extra.project.path)
end

function M.choose_launch_profile(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  require("dotnet-tree.launch_profile").pick(node.extra.project.path)
end

function M.watch(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "run", "test", "build" }, { prompt = "dotnet watch:" }, function(choice)
    if not choice then
      return
    end
    local path = node.extra.project.path
    local function start(extra_args)
      terminal.open(
        "dotnet watch " .. choice .. " --project " .. vim.fn.shellescape(path) .. extra_args,
        "watch " .. choice .. " " .. terminal.project_name(path),
        project_dir(path)
      )
    end
    if choice ~= "run" then
      start("")
      return
    end
    if not prepare_function_app(path, true) then
      return
    end
    local launch_profile = require("dotnet-tree.launch_profile")
    launch_profile.choose(path, function(profile)
      start(launch_profile.args(profile))
    end)
  end)
end

-- ─── the .NET actions, behind `,` ──────────────────────────────────────────
--
-- The .NET actions are mapped as `,b`, `,r`, `,d`... A mapping of two keys
-- only waits 'timeoutlen' for the second: with a short one, as many
-- configurations set, a pause after `,` dropped it, and `r` or `d` alone ran
-- their file operation -- rename, delete -- instead of run or debug. So `,`
-- is a key of its own: it shows what can follow, waits for that key for as
-- long as it takes, and runs the action the `,` mapping for it names.
--
-- `,` fires at once because neo-tree maps with nowait by default; with nowait
-- off it fires after 'timeoutlen', and a quick `,r` runs the `,r` mapping
-- directly. Either way `r` alone never runs. The actions are read from the
-- `,` mappings of the configuration, so remapped or added ones work and show
-- up, as long as one key follows `,` (`,x`, `,<C-r>`): with nowait a longer
-- `,…` sequence could never be reached, so it is reported instead.

local DISABLED = { none = true, nop = true, noop = true }

-- A key as `keytrans` writes it, the form both a mapping and a typed key reach
local function key_name(keys)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(keys, true, true, true))
end

local warned_sequences = {}

-- The `,` + one key mappings of the source, as a list of { key, name,
-- command, config, desc } sorted by key; desc loses its `[.NET]` tag
local function prefixed_actions(state)
  local actions = {}
  for lhs, value in pairs(state.window and state.window.mappings or {}) do
    local rest = type(lhs) == "string" and lhs:match("^,(.+)$")
    if rest then
      local command, desc, config = value, nil, nil
      if type(value) == "table" then
        command, desc, config = value[1] or value.command, value.desc, value.config
      end
      local name = key_name(rest)
      if vim.fn.strcharlen(vim.api.nvim_replace_termcodes(rest, true, true, true)) ~= 1 then
        if not warned_sequences[lhs] then
          warned_sequences[lhs] = true
          warn(("`%s` is more than one key after `,`, and only one is read after it: map it to one key"):format(lhs))
        end
      elseif command and not (type(command) == "string" and DISABLED[command]) then
        desc = desc or (type(command) == "string" and command or "")
        table.insert(actions, {
          key = rest,
          name = name,
          command = command,
          config = config,
          desc = (desc:gsub("^%[%.NET%]%s*", "")),
        })
      end
    end
  end
  -- Each lower-case key before its upper-case one, the rest alphabetically
  table.sort(actions, function(a, b)
    if a.key:lower() ~= b.key:lower() then
      return a.key:lower() < b.key:lower()
    end
    return a.key > b.key
  end)
  return actions
end

-- The actions, one line each, as the float shows them
local function action_lines(actions)
  return vim.tbl_map(function(action)
    return (" %s  %s"):format(action.key, action.desc)
  end, actions)
end

-- A float at the bottom-left of the tree window listing the `,` actions; nil,
-- and the buffer gone, when it cannot be opened
local function show_actions(state, actions)
  local lines = action_lines(actions)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 1)
  end
  local parent = state.winid and vim.api.nvim_win_is_valid(state.winid) and state.winid
    or vim.api.nvim_get_current_win()
  width = math.min(width, math.max(vim.api.nvim_win_get_width(parent) - 2, 10))
  local height = math.min(#lines, math.max(vim.api.nvim_win_get_height(parent) - 2, 1))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, action in ipairs(actions) do
    vim.api.nvim_buf_add_highlight(buf, -1, "Special", i - 1, 1, 1 + #action.key)
  end
  vim.bo[buf].bufhidden = "wipe"
  local config = {
    relative = "win",
    win = parent,
    anchor = "SW",
    row = vim.api.nvim_win_get_height(parent),
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " dotnet-tree ",
    title_pos = "left",
    focusable = false,
    zindex = 250,
  }
  -- A footer needs Neovim 0.10
  if vim.fn.has("nvim-0.10") == 1 then
    config.footer = " <esc> cancel "
    config.footer_pos = "right"
  end
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, config)
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil
  end
  return win
end

-- Keys that mean "never mind": <esc>, <C-c>, and a click or a scroll, which
-- is not a key at all
local function cancels(key)
  return key == "" or key == "\27" or key == "\3" or key:sub(1, 1) == "\128"
end

--- `,`: wait for the key of a .NET action, showing them, then run it.
function M.dotnet_actions(state)
  local actions = prefixed_actions(state)
  if #actions == 0 then
    warn("no .NET actions are mapped under `,`")
    return
  end
  local win = show_actions(state, actions)
  if not win then
    -- No float: the command line says what is awaited, so the next key is not
    -- taken without notice
    vim.api.nvim_echo({ { ".NET: ", "ModeMsg" }, { table.concat(action_lines(actions), " ·"), "Normal" } }, false, {})
  end
  vim.cmd("redraw")
  local ok, key = pcall(vim.fn.getcharstr)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if not win then
    vim.api.nvim_echo({ { "" } }, false, {})
  end
  if not ok or cancels(key) then
    return
  end
  local typed = vim.fn.keytrans(key)
  for _, action in ipairs(actions) do
    if action.name == typed then
      local command = action.command
      local fn = type(command) == "function" and command or (state.commands and state.commands[command]) or M[command]
      if type(fn) ~= "function" then
        warn(("`,%s` is mapped to %s, which the .NET tree does not have"):format(action.key, tostring(command)))
        return
      end
      -- What neo-tree gives a command it calls: the mapping's own config
      state.config = action.config or {}
      return fn(state)
    end
  end
  warn(("no .NET action on `,%s`; `,` shows them"):format(typed))
end

-- ─── file operations (#50) ─────────────────────────────────────────────────
--
-- Adding, renaming, moving, copying and deleting go through neo-tree's own
-- file operations, which confirm a delete, rename open buffers and fire the
-- events other plugins listen to. What a node stands for decides what an
-- operation does: a file or folder of a project is on disk, a solution item is
-- listed in the solution, and a package, a reference or a project is undone
-- with the `dotnet` command that added it.

local function fs_actions()
  return require("neo-tree.sources.filesystem.lib.fs_actions")
end

local function display(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

-- Rebuild the tree and, when `path` is in it, put the cursor on it
local function reveal_after(state, path)
  local ok, err = pcall(function()
    require("neo-tree.sources.manager").navigate(state, state.path, nil, function()
      local id = path and state.dotnet_index and reveal.lookup(state.dotnet_index, path)
      if id then
        local focused, focus_err = pcall(reveal.focus, state, id)
        if not focused then
          warn(("could not put the cursor on %s: %s"):format(display(path), tostring(focus_err)))
        end
      end
    end)
  end)
  if not ok then
    warn("could not redraw the tree, rebuilding it: " .. tostring(err))
    require("dotnet-tree.refresh").rebuild()
  end
end

-- Why a node that has no file of its own cannot be acted on like one
local NOT_A_FILE = {
  package = "a package is not a file in the project",
  project_reference = "a project reference is not a file in this project",
  packages = "this groups the packages, it is not a folder",
  projrefs = "this groups the project references, it is not a folder",
  dependencies = "this groups the dependencies, it is not a folder",
  frameworks = "this groups the target frameworks, it is not a folder",
  framework = "a target framework is not a file",
}

-- What the verb reads like in a refusal, for the nodes the solution manages
local DONE = { rename = "renamed", move = "moved", copy = "copied", cut = "moved", delete = "deleted" }

local function refusal(op, node)
  local kind = node.extra and node.extra.kind
  local done = DONE[op] or op
  local why = NOT_A_FILE[kind]
  if kind == "solution" then
    why = ("the solution file is not %s from the tree"):format(done)
  elseif kind == "sln_folder" then
    why = ("a solution folder only exists in the solution file, and is not %s from the tree yet"):format(done)
  elseif kind == "project" then
    why = ("a project is %s in its file and in the solution, which is not done from the tree"):format(done)
  end
  return ("cannot %s %s: %s"):format(op, node.name or "this", why or "it is not a file")
end

--- The file or folder on disk an operation on `node` acts on, or why there is
--- none. `op` only words the refusal.
---@param op string
---@return table|nil { node, path, is_dir, sln_folder = guid of the folder listing it }
---@return string|nil reason
local function node_target(state, node, op)
  local extra = node.extra or {}
  if extra.kind == "folder" and node.path then
    return { node = node, path = node.path, is_dir = true }
  elseif extra.kind == "file" and node.path then
    if extra.sln_folder then
      return { node = node, path = node.path, sln_folder = extra.sln_folder }
    end
    -- The project node above this one, through the tree's parent links
    local parent_id = node.get_parent_id and node:get_parent_id()
    local parent = parent_id and state.tree:get_node(parent_id)
    while parent and not (parent.extra and parent.extra.kind == "project") do
      parent_id = parent.get_parent_id and parent:get_parent_id()
      parent = parent_id and state.tree:get_node(parent_id)
    end
    if parent and parent.extra.project and parent.extra.project.path == node.path then
      return nil,
        ("cannot %s %s: the project file goes with its project, in the solution too"):format(op, node.name or "it")
    end
    return { node = node, path = node.path }
  end
  return nil, refusal(op, node)
end

local function disk_target(state, op)
  local node = state.tree:get_node()
  if not node then
    return nil
  end
  return node_target(state, node, op)
end

-- The directory a paste or a new file goes into, from the node under the
-- cursor: a folder itself, the folder of a project's file, a project's directory.
local function target_dir(state, what)
  local node = state.tree:get_node()
  local extra = node and node.extra or {}
  if extra.kind == "folder" and node.path then
    return node.path
  elseif extra.kind == "file" and node.path and not extra.sln_folder then
    return vim.fn.fnamemodify(node.path, ":h")
  elseif extra.kind == "project" and extra.project and extra.project.path then
    return vim.fn.fnamemodify(extra.project.path, ":h")
  elseif extra.kind == "sln_folder" or extra.sln_folder then
    warn(("%s in a project: in a solution folder, `n` creates a file and `a` adds one"):format(what))
    return
  end
  warn(("%s on a project, one of its folders or one of its files"):format(what))
end

-- After a file or folder moved, write the new path of every solution item it
-- was, or held: a file can be reached through its project as well as through
-- a solution folder.
local function update_items(state, old, new, is_dir)
  if not state.dotnet_sln then
    return
  end
  local edit = require("dotnet-tree.solution_edit")
  local solution = require("dotnet-tree.parser.solution")
  solution.invalidate(state.dotnet_sln)
  local sln = solution.parse(state.dotnet_sln)
  if not sln then
    return
  end
  local prefix = vim.fs.normalize(old) .. "/"
  for _, folder in ipairs(sln.projects) do
    for _, item in ipairs(folder.solution_items or {}) do
      local item_path = vim.fs.normalize(item.path)
      local moved_to
      if edit.same_path(item_path, old) then
        moved_to = new
      elseif is_dir and item_path:sub(1, #prefix) == prefix then
        moved_to = new .. "/" .. item_path:sub(#prefix + 1)
      end
      if moved_to then
        local ok, err = edit.rename_item(state.dotnet_sln, folder, item.path, moved_to)
        if not ok then
          warn(
            ("moved %s, but %s still lists its old path (%s): fix it there, or take it off and add it"):format(
              display(item.path),
              vim.fn.fnamemodify(state.dotnet_sln, ":t"),
              err
            )
          )
        end
      end
    end
  end
end

-- The project file nearest above `path`
local function project_file_of(path)
  return vim.fs.find(function(name)
    return name:match("%.[cfv][sb]proj$") ~= nil
  end, { upward = true, path = vim.fn.fnamemodify(path, ":h"), limit = 1 })[1]
end

-- A file the project names (`<None Update="appsettings.json">`, a
-- `<Compile Remove>`, an embedded resource) is not renamed in the project with
-- it: say where to do it, rather than rewrite the project
local function warn_if_named(path, done)
  local project = project_file_of(path)
  if not project then
    return
  end
  local f = io.open(project, "r")
  if not f then
    return
  end
  local content = f:read("*a"):lower()
  f:close()
  local rel = require("dotnet-tree.solution_edit").relative(vim.fn.fnamemodify(project, ":h"), path):lower()
  if content:find(rel, 1, true) or content:find((rel:gsub("/", "\\")), 1, true) then
    warn(
      ("%s is named in %s, which still points to it: update it there"):format(
        vim.fn.fnamemodify(path, ":t"),
        vim.fn.fnamemodify(project, ":t")
      )
    )
  end
  return done
end

-- The nearest directory of `path` that exists
local function existing_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  while vim.fn.isdirectory(dir) == 0 do
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
  return dir
end

-- What would make neo-tree refuse or fail a move to `dest`, said before
-- anything else happens: the language servers' edits are applied before the
-- move, and neo-tree does not report back when it gives up.
local function cannot_move(target, dest)
  local src = vim.fs.normalize(target.path)
  local stat = vim.uv.fs_stat(src)
  if not stat then
    return ("%s is no longer there"):format(display(src))
  elseif dest == src then
    return ("%s is already there"):format(display(src))
  elseif target.is_dir and dest:sub(1, #src + 1) == src .. "/" then
    return ("cannot move %s into itself"):format(display(src))
  end
  local edit = require("dotnet-tree.solution_edit")
  -- On a file system that ignores case, a new case is the same file
  if vim.uv.fs_stat(dest) and not edit.same_path(src, dest) then
    return ("%s already exists"):format(display(dest))
  end
  local parent = existing_dir(dest)
  if not parent then
    return ("cannot move %s there: no such directory"):format(display(src))
  end
  local parent_stat = vim.uv.fs_stat(parent)
  if parent_stat and parent_stat.dev ~= stat.dev then
    return ("%s is on another volume: move it outside the tree"):format(display(dest))
  end
  if not vim.uv.fs_access(parent, "W") then
    return ("%s is not writable"):format(display(parent))
  end
end

-- Move or rename `target` to `dest`, telling the language servers; `on_done`
-- runs once it has moved
local function relocate(state, target, dest, verb, on_done)
  dest = vim.fs.normalize(dest)
  local problem = cannot_move(target, dest)
  if problem then
    warn(problem)
    return
  end
  local lsp = require("dotnet-tree.lsp_files")
  local edits = lsp.will_rename(target.path, dest)
  if edits.err then
    warn(edits.err .. ("; %s was not %s"):format(display(target.path), verb))
    return
  end
  fs_actions().move_node(target.path, dest, function(_, final)
    lsp.did_rename(target.path, final)
    update_items(state, target.path, final, target.is_dir)
    if not target.is_dir then
      warn_if_named(target.path)
    end
    local by = ""
    if edits.files > 0 then
      by = (" (%d %s edited by %s, not saved yet: :wa)"):format(
        edits.files,
        edits.files == 1 and "file" or "files",
        table.concat(edits.servers, ", ")
      )
    end
    -- Within one folder the names say it, and a short line needs no Enter
    local same_dir = vim.fn.fnamemodify(target.path, ":h") == vim.fn.fnamemodify(final, ":h")
    local from = same_dir and vim.fn.fnamemodify(target.path, ":t") or display(target.path)
    local to = same_dir and vim.fn.fnamemodify(final, ":t") or display(final)
    info(("%s %s to %s%s"):format(verb, from, to, by))
    reveal_after(state, final)
    if on_done then
      on_done()
    end
  end, "")
end

local function refuse_if(reason)
  if reason then
    warn(reason)
  end
end

local function ask_name(state, default, prompt_name, to_name)
  local target, reason = disk_target(state, "rename")
  if not target then
    return refuse_if(reason)
  end
  vim.ui.input({ prompt = ("Rename %s to: "):format(prompt_name(target)), default = default(target) }, function(answer)
    answer = answer and vim.trim(answer)
    if not answer or answer == "" or answer == default(target) then
      return
    end
    if answer:find("[/\\]") then
      warn("give a name, not a path: `m` moves")
      return
    end
    relocate(state, target, vim.fn.fnamemodify(target.path, ":h") .. "/" .. to_name(target, answer), "renamed")
  end)
end

local function tail(target)
  return vim.fn.fnamemodify(target.path, ":t")
end

function M.rename(state)
  ask_name(state, tail, tail, function(_, answer)
    return answer
  end)
end

--- `b`: rename without retyping the extension.
function M.rename_basename(state)
  ask_name(
    state,
    function(target)
      return vim.fn.fnamemodify(target.path, ":t:r")
    end,
    tail,
    function(target, answer)
      local ext = vim.fn.fnamemodify(target.path, ":e")
      return ext ~= "" and (answer .. "." .. ext) or answer
    end
  )
end

-- A path typed at a prompt, absolute: `~` is expanded and a relative path is
-- taken from the working directory. `%`, `$VAR` and wildcards are kept as
-- written, as the names of files they are.
local function typed_path(input)
  local path = vim.fs.normalize(input)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = vim.fs.normalize(vim.fn.getcwd() .. "/" .. path)
  end
  return path
end

-- Ask where `target` goes: a path, or a directory that keeps its name
local function ask_destination(target, verb, cb)
  vim.ui.input({
    prompt = ("%s %s to: "):format(verb, tail(target)),
    default = display(target.path),
    completion = "file",
  }, function(input)
    input = input and vim.trim(input)
    if not input or input == "" then
      return
    end
    local dest = typed_path(input)
    if input:match("[/\\]$") or vim.fn.isdirectory(dest) == 1 then
      dest = dest .. "/" .. tail(target)
    end
    cb(vim.fs.normalize(dest))
  end)
end

function M.move(state)
  local target, reason = disk_target(state, "move")
  if not target then
    return refuse_if(reason)
  end
  ask_destination(target, "Move", function(dest)
    relocate(state, target, dest, "moved")
  end)
end

-- Copy `target` to `dest`, the way `p` pastes a copy; `on_done` once copied
local function duplicate(state, target, dest, on_done)
  if not vim.uv.fs_stat(target.path) then
    warn(("%s is no longer there"):format(display(target.path)))
    return
  end
  if vim.uv.fs_stat(dest) then
    warn(("%s already exists: `c` copies it under another name"):format(display(dest)))
    return
  end
  fs_actions().copy_node(target.path, dest, function(_, final)
    info(("copied %s to %s"):format(display(target.path), display(final)))
    reveal_after(state, final)
    if on_done then
      on_done()
    end
  end, "")
end

--- `c`: copy to a path asked for.
function M.copy(state)
  local target, reason = disk_target(state, "copy")
  if not target then
    return refuse_if(reason)
  end
  ask_destination(target, "Copy", function(dest)
    duplicate(state, target, dest)
  end)
end

-- Several nodes act together only when all are files or folders of projects:
-- a selection reaching a package, a project or a solution item would do more
-- than it shows. Returns the targets, or nil once the refusal is said.
local function selected_targets(state, nodes, op)
  local targets, others = {}, {}
  for _, node in ipairs(nodes or {}) do
    local target = node_target(state, node, op)
    if target and not target.sln_folder then
      table.insert(targets, target)
    else
      table.insert(others, node.name or "?")
    end
  end
  if #others > 0 then
    warn(
      ("only files and folders of projects can be %s together, not %s: the rest one at a time"):format(
        DONE[op] or op,
        table.concat(others, ", ")
      )
    )
    return nil
  end
  return targets
end

local function names_of(targets)
  return table.concat(
    vim.tbl_map(function(target)
      return tail(target)
    end, targets),
    ", "
  )
end

local function to_clipboard(state, action, targets)
  state.dotnet_clipboard = { action = action, targets = targets }
  info(("%s %s: press p where it goes"):format(action == "copy" and "copied" or "cut", names_of(targets)))
end

function M.copy_to_clipboard(state)
  local target, reason = disk_target(state, "copy")
  if not target then
    return refuse_if(reason)
  end
  to_clipboard(state, "copy", { target })
end

function M.cut_to_clipboard(state)
  local target, reason = disk_target(state, "cut")
  if not target then
    return refuse_if(reason)
  end
  to_clipboard(state, "cut", { target })
end

function M.copy_to_clipboard_visual(state, nodes)
  local targets = selected_targets(state, nodes, "copy")
  if targets then
    to_clipboard(state, "copy", targets)
  end
end

function M.cut_to_clipboard_visual(state, nodes)
  local targets = selected_targets(state, nodes, "cut")
  if targets then
    to_clipboard(state, "cut", targets)
  end
end

function M.clear_clipboard(state)
  state.dotnet_clipboard = nil
end

function M.paste_from_clipboard(state)
  local clip = state.dotnet_clipboard
  if not clip or #clip.targets == 0 then
    warn("nothing to paste: y copies and x cuts")
    return
  end
  local dir = target_dir(state, "paste")
  if not dir then
    return
  end
  for _, target in ipairs(vim.list_slice(clip.targets)) do
    local dest = dir .. "/" .. tail(target)
    if clip.action == "cut" then
      -- A cut is pasted once: each one leaves the clipboard when it has moved
      relocate(state, target, dest, "moved", function()
        for i, t in ipairs(clip.targets) do
          if t == target then
            table.remove(clip.targets, i)
            break
          end
        end
        if #clip.targets == 0 and state.dotnet_clipboard == clip then
          state.dotnet_clipboard = nil
        end
      end)
    else
      duplicate(state, target, dest)
    end
  end
end

--- `a`: what adding means on the node. On a solution folder, an existing file
--- (see the solution folders above); on packages or project references, one
--- more; anywhere else in a project, a new file -- or a folder, when the name
--- ends in `/` -- of any kind, not only a .cs one from a template.
function M.add(state)
  local node = state.tree:get_node()
  if not node then
    return
  end
  local target = solution_target(state)
  if target and target.guid then
    solution_add(state, target)
    return
  elseif target then
    warn("nothing to add to the solution itself: `n` creates a solution folder")
    return
  end
  local kind = node.extra and node.extra.kind
  if kind == "packages" or kind == "package" or kind == "projrefs" or kind == "project_reference" then
    M.add_package_or_reference(state)
    return
  end
  local dir = target_dir(state, "a new file goes")
  if not dir then
    return
  end
  fs_actions().create_node(dir, function(dest)
    reveal_after(state, dest)
  end, dir)
end

function M.add_directory(state)
  local dir = target_dir(state, "a new folder goes")
  if not dir then
    return
  end
  fs_actions().create_directory(dir, function(dest)
    if vim.fn.isdirectory(dest) == 0 then
      warn(("could not create %s"):format(display(dest)))
      return
    end
    reveal_after(state, dest)
  end, dir)
end

local function confirm(message, cb)
  require("neo-tree.ui.inputs").confirm(message, function(yes)
    if yes then
      cb()
    end
  end)
end

local REMOVABLE = { project = true, package = true, project_reference = true }

-- `d` on a package, a project reference or a project: undo what added it,
-- with the `dotnet` command that did. Returns whether `node` is one of them.
local function delete_from_project(state, node)
  local kind = node.extra and node.extra.kind
  if not REMOVABLE[kind] then
    return false
  end
  local project = find_project_node(state)
  local csproj = project and project.extra.project and project.extra.project.path
  if not csproj then
    warn(("cannot remove %s: the project it belongs to was not found; press R"):format(node.name or "it"))
  elseif kind == "project" then
    if not state.dotnet_sln then
      warn("no solution loaded")
      return true
    end
    confirm(("Remove %s from the solution? Its files stay on disk."):format(node.name), function()
      local sln = state.dotnet_sln
      terminal.open(
        "dotnet sln " .. vim.fn.shellescape(sln) .. " remove " .. vim.fn.shellescape(csproj),
        "remove " .. node.name .. " from " .. vim.fn.fnamemodify(sln, ":t")
      )
    end)
  elseif kind == "package" then
    local package = node.extra.package.name
    confirm(("Remove package %s from %s?"):format(package, project.name), function()
      terminal.open(
        "dotnet remove " .. vim.fn.shellescape(csproj) .. " package " .. vim.fn.shellescape(package),
        "remove " .. package .. " from " .. terminal.project_name(csproj)
      )
    end)
  elseif not node.path then
    warn(("cannot remove the reference to %s: its path is not known; press R"):format(node.name or "it"))
  else
    confirm(("Remove the reference to %s from %s?"):format(node.name, project.name), function()
      terminal.open(
        "dotnet remove " .. vim.fn.shellescape(csproj) .. " reference " .. vim.fn.shellescape(node.path),
        "remove " .. node.name .. " from " .. terminal.project_name(csproj)
      )
    end)
  end
  return true
end

function M.delete(state)
  local node = state.tree:get_node()
  if not node then
    return
  end
  if delete_from_project(state, node) then
    return
  end
  local target, reason = disk_target(state, "delete")
  if not target then
    return refuse_if(reason)
  end
  if target.sln_folder then
    local _, folder = load_solution(state, target.sln_folder)
    if not folder then
      return
    end
    local name = tail(target)
    confirm(("Take %s off %s? The file stays on disk."):format(name, folder.name), function()
      local ok, err = require("dotnet-tree.solution_edit").remove_item(state.dotnet_sln, folder, target.path)
      if not ok then
        warn(err)
        return
      end
      info(("took %s off %s"):format(name, folder.name))
      reveal_after(state, nil)
    end)
    return
  end
  -- neo-tree asks first and says what it deleted
  fs_actions().delete_node(target.path, function()
    if not target.is_dir then
      warn_if_named(target.path)
    end
    reveal_after(state, vim.fn.fnamemodify(target.path, ":h"))
  end)
end

--- `d` on a selection: files and folders of projects only, after one question.
function M.delete_visual(state, nodes)
  local targets = selected_targets(state, nodes, "delete")
  if not targets or #targets == 0 then
    return
  end
  confirm(("Delete %s?"):format(names_of(targets)), function()
    local left = #targets
    for _, target in ipairs(targets) do
      fs_actions().delete_node(target.path, function()
        left = left - 1
        if left == 0 then
          reveal_after(state, vim.fn.fnamemodify(target.path, ":h"))
        end
      end, true)
    end
  end)
end

-- neo-tree's trash and its undo work on its filesystem source; here `d` deletes
local function no_trash()
  warn("there is no trash in the .NET tree: `d` deletes, after asking")
end
M.trash, M.trash_visual, M.restore_from_trash, M.restore_from_trash_visual, M.undo =
  no_trash, no_trash, no_trash, no_trash, no_trash

-- neo-tree's open commands, behind the same check as `open`: a node with no
-- file of its own (a package, a group, the solution) is toggled, never opened
-- as a buffer named after its id
for name, fn in pairs(cc) do
  if type(fn) == "function" and (name:match("^open_") or name:match("with_window_picker$")) then
    M[name] = function(state, ...)
      local node = state.tree:get_node()
      local kind = node and node.extra and node.extra.kind
      if node and (NON_OPENABLE[kind] or not node.path) then
        return M.open(state)
      end
      return fn(state, ...)
    end
  end
end

return M
