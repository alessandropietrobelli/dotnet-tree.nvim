local cc = require("neo-tree.sources.common.commands")
local reveal = require("dotnet-tree.reveal")
local terminal = require("dotnet-tree.terminal")

local M = {}
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
  local dotnet, other = {}, {}

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
      if label then
        table.insert(dotnet, { key = key, desc = label })
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

-- `r`, `t` and `w` start in the project's folder, not in Neovim's: a function
-- app's host is found relative to it (#57), and the default host of an
-- ASP.NET Core app reads appsettings.json from its working directory.
local function project_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

local FUNC_INSTALL = "https://learn.microsoft.com/azure/azure-functions/functions-run-local"

-- What starting the project at `path` with `r` (`watch` false) or `w` → run
-- (`watch` true) needs when it is an Azure Functions app (#57): `func` on
-- PATH, and Azurite when the app uses it, which is checked in the background
-- and only warned about. `dotnet watch` cannot start the host of an app that
-- `dotnet run` cannot start either, so `w` refuses those and points to `r`.
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
      .. "runs with `func start`. Press `r` instead."
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

-- `d`: build the project under the cursor, then start netcoredbg on what it
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

-- ─── file operations (#50) ─────────────────────────────────────────────────
--
-- Renaming, moving, copying and deleting go through neo-tree's own file
-- operations, which ask for confirmation, rename open buffers and fire the
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
        pcall(reveal.focus, state, id)
      end
    end)
  end)
  if not ok then
    warn("could not redraw the tree, rebuilding it: " .. tostring(err))
    require("dotnet-tree.refresh").rebuild()
  end
end

-- Why each kind of node has nothing on disk to rename, move or copy
local NOT_ON_DISK = {
  solution = "the solution file is not renamed or moved from the tree",
  sln_folder = "a solution folder only exists in the solution file; renaming it is not done from the tree yet",
  project = "a project is renamed in its file and in the solution, which is not done from the tree",
  package = "a package is not a file in the project",
  project_reference = "a project reference is not a file in this project",
  packages = "this groups the packages; it is not a folder",
  projrefs = "this groups the project references; it is not a folder",
  dependencies = "this groups the dependencies; it is not a folder",
  frameworks = "this groups the target frameworks; it is not a folder",
  framework = "a target framework is not a file",
}

--- The file or folder on disk an operation acts on, or why there is none.
---@return table|nil { node, path, is_dir, sln_folder = guid of the folder listing it }
---@return string|nil reason
local function disk_target(state, op)
  local node = state.tree:get_node()
  if not node then
    return nil
  end
  local extra = node.extra or {}
  local name = node.name or "this"
  if extra.kind == "folder" and node.path then
    return { node = node, path = node.path, is_dir = true }
  elseif extra.kind == "file" and node.path then
    if extra.sln_folder then
      return { node = node, path = node.path, sln_folder = extra.sln_folder }
    end
    local project = find_project_node(state)
    if project and project.extra.project and project.extra.project.path == node.path then
      return nil, ("cannot %s %s: the project file goes with its project, in the solution too"):format(op, name)
    end
    return { node = node, path = node.path }
  end
  return nil, ("cannot %s %s: %s"):format(op, name, NOT_ON_DISK[extra.kind] or "it is not a file")
end

-- The directory a paste or a new folder goes into, from the node under the
-- cursor: a folder itself, the folder of a file, a project's directory.
local function target_dir(state, op)
  local node = state.tree:get_node()
  local extra = node and node.extra or {}
  if extra.kind == "folder" and node.path then
    return node.path
  elseif extra.kind == "file" and node.path and not extra.sln_folder then
    return vim.fn.fnamemodify(node.path, ":h")
  elseif extra.kind == "project" and extra.project and extra.project.path then
    return vim.fn.fnamemodify(extra.project.path, ":h")
  end
  warn(("%s on a project, one of its folders or one of its files"):format(op))
end

-- After a solution item moved on disk, write its new path in the solution
local function update_item(state, target, dest)
  if not target.sln_folder then
    return
  end
  local _, folder = load_solution(state, target.sln_folder)
  if not folder then
    return
  end
  local ok, err = require("dotnet-tree.solution_edit").rename_item(state.dotnet_sln, folder, target.path, dest)
  if not ok then
    warn(("moved %s, but the solution still lists the old path: %s"):format(display(target.path), err))
  end
end

-- Move or rename `target` to `dest`, telling the language servers
local function relocate(state, target, dest, verb)
  dest = vim.fs.normalize(dest)
  if dest == vim.fs.normalize(target.path) then
    return
  end
  local exists = vim.uv.fs_stat(dest)
  -- On a file system that ignores case, a new case is the same file
  if exists and not require("dotnet-tree.solution_edit").same_path(target.path, dest) then
    warn(("%s already exists"):format(display(dest)))
    return
  end
  local lsp = require("dotnet-tree.lsp_files")
  local servers = lsp.will_rename(target.path, dest)
  fs_actions().move_node(target.path, dest, function(_, final)
    lsp.did_rename(target.path, final)
    update_item(state, target, final)
    local by = #servers > 0 and (" (code updated by %s)"):format(table.concat(servers, ", ")) or ""
    info(("%s %s to %s%s"):format(verb, display(target.path), display(final), by))
    reveal_after(state, final)
  end, "")
end

function M.rename(state)
  local target, reason = disk_target(state, "rename")
  if not target then
    if reason then
      warn(reason)
    end
    return
  end
  local name = vim.fn.fnamemodify(target.path, ":t")
  vim.ui.input({ prompt = ("Rename %s to: "):format(name), default = name }, function(new_name)
    new_name = new_name and vim.trim(new_name)
    if not new_name or new_name == "" or new_name == name then
      return
    end
    if new_name:find("[/\\]") then
      warn("give a name, not a path: `m` moves")
      return
    end
    relocate(state, target, vim.fn.fnamemodify(target.path, ":h") .. "/" .. new_name, "renamed")
  end)
end

--- `b`: rename without retyping the extension.
function M.rename_basename(state)
  local target, reason = disk_target(state, "rename")
  if not target then
    if reason then
      warn(reason)
    end
    return
  end
  local name = vim.fn.fnamemodify(target.path, ":t")
  local ext = vim.fn.fnamemodify(target.path, ":e")
  local base = vim.fn.fnamemodify(target.path, ":t:r")
  vim.ui.input({ prompt = ("Rename %s to: "):format(name), default = base }, function(new_base)
    new_base = new_base and vim.trim(new_base)
    if not new_base or new_base == "" or new_base == base then
      return
    end
    if new_base:find("[/\\]") then
      warn("give a name, not a path: `m` moves")
      return
    end
    local new_name = ext ~= "" and (new_base .. "." .. ext) or new_base
    relocate(state, target, vim.fn.fnamemodify(target.path, ":h") .. "/" .. new_name, "renamed")
  end)
end

-- Ask where `target` goes: a path, or a directory that keeps its name
local function ask_destination(target, verb, cb)
  vim.ui.input({
    prompt = ("%s %s to: "):format(verb, vim.fn.fnamemodify(target.path, ":t")),
    default = display(target.path),
    completion = "file",
  }, function(input)
    input = input and vim.trim(input)
    if not input or input == "" then
      return
    end
    local dest = vim.fn.fnamemodify(vim.fn.expand(input), ":p")
    if input:sub(-1) == "/" or vim.fn.isdirectory(dest) == 1 then
      dest = dest:gsub("/$", "") .. "/" .. vim.fn.fnamemodify(target.path, ":t")
    end
    cb(vim.fs.normalize(dest))
  end)
end

function M.move(state)
  local target, reason = disk_target(state, "move")
  if not target then
    if reason then
      warn(reason)
    end
    return
  end
  ask_destination(target, "Move", function(dest)
    relocate(state, target, dest, "moved")
  end)
end

-- Copy `target` to `dest`, the way `p` pastes a copy
local function duplicate(state, target, dest)
  if vim.uv.fs_stat(dest) then
    warn(("%s already exists"):format(display(dest)))
    return
  end
  fs_actions().copy_node(target.path, dest, function(_, final)
    info(("copied %s to %s"):format(display(target.path), display(final)))
    reveal_after(state, final)
  end, "")
end

--- `c`: copy to a path asked for.
function M.copy(state)
  local target, reason = disk_target(state, "copy")
  if not target then
    if reason then
      warn(reason)
    end
    return
  end
  ask_destination(target, "Copy", function(dest)
    duplicate(state, target, dest)
  end)
end

local function to_clipboard(state, action)
  local target, reason = disk_target(state, action)
  if not target then
    if reason then
      warn(reason)
    end
    return
  end
  state.dotnet_clipboard = { action = action, target = target }
  info(("%s %s: press p on a folder to paste it"):format(action == "copy" and "copied" or "cut", display(target.path)))
end

function M.copy_to_clipboard(state)
  to_clipboard(state, "copy")
end

function M.cut_to_clipboard(state)
  to_clipboard(state, "cut")
end

function M.paste_from_clipboard(state)
  local clip = state.dotnet_clipboard
  if not clip then
    warn("nothing to paste: y copies and x cuts")
    return
  end
  local dir = target_dir(state, "paste")
  if not dir then
    return
  end
  local dest = dir .. "/" .. vim.fn.fnamemodify(clip.target.path, ":t")
  if clip.action == "cut" then
    state.dotnet_clipboard = nil
    relocate(state, clip.target, dest, "moved")
    return
  end
  duplicate(state, clip.target, dest)
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

-- `D` on what is not a file: undo what added it, with the command that did
local function delete_from_project(state, node)
  local kind = node.extra.kind
  local project = find_project_node(state)
  local csproj = project and project.extra.project and project.extra.project.path
  if kind == "project" and csproj then
    if not state.dotnet_sln then
      warn("no solution loaded")
      return
    end
    confirm(("Remove %s from the solution? Its files stay on disk."):format(node.name), function()
      local sln = state.dotnet_sln
      terminal.open(
        "dotnet sln " .. vim.fn.shellescape(sln) .. " remove " .. vim.fn.shellescape(csproj),
        "remove " .. node.name .. " from " .. vim.fn.fnamemodify(sln, ":t")
      )
    end)
  elseif kind == "package" and csproj then
    local package = node.extra.package.name
    confirm(("Remove package %s from %s?"):format(package, project.name), function()
      terminal.open(
        "dotnet remove " .. vim.fn.shellescape(csproj) .. " package " .. vim.fn.shellescape(package),
        "remove " .. package .. " from " .. terminal.project_name(csproj)
      )
    end)
  elseif kind == "project_reference" and csproj and node.path then
    confirm(("Remove the reference to %s from %s?"):format(node.name, project.name), function()
      terminal.open(
        "dotnet remove " .. vim.fn.shellescape(csproj) .. " reference " .. vim.fn.shellescape(node.path),
        "remove " .. node.name .. " from " .. terminal.project_name(csproj)
      )
    end)
  else
    return false
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
    if reason then
      warn(reason)
    end
    return
  end
  if target.sln_folder then
    local _, folder = load_solution(state, target.sln_folder)
    if not folder then
      return
    end
    local name = vim.fn.fnamemodify(target.path, ":t")
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
  -- neo-tree says what it deleted
  fs_actions().delete_node(target.path, function()
    reveal_after(state, vim.fn.fnamemodify(target.path, ":h"))
  end)
end

-- neo-tree's own commands for what this source does not do differently:
-- opening in a split, a tab or a picked window, the preview, closing the
-- window, so its default keys work here as in its other sources. `add`,
-- `delete` and the like are not taken: they read the node id as a path, which
-- it is not here.
for _, pattern in ipairs({
  "^open",
  "^split_with",
  "^vsplit_with",
  "preview",
  "^close_window$",
  "^toggle_auto_expand_width$",
  "^show_file_details$",
  "^cancel$",
  "_source$",
}) do
  if cc._add_common_commands then
    cc._add_common_commands(M, pattern)
  end
end

return M
