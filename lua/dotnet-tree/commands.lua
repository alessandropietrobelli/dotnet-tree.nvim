local cc = require("neo-tree.sources.common.commands")

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
  local slns = vim.fn.globpath(cwd, "*.sln", false, true)
  if #slns == 0 then
    slns = vim.fn.globpath(cwd, "**/*.sln", false, true)
  end
  if #slns == 0 then
    vim.notify("[dotnet-tree] no .sln found", vim.log.levels.WARN)
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

function M.toggle_node(state)
  cc.toggle_node(state)
end

function M.close_node(state)
  cc.close_node(state)
end

function M.close_all_nodes(state)
  cc.close_all_nodes(state)
end

function M.expand_all_nodes(state)
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

local function run_in_terminal(cmd)
  vim.cmd("botright 15split")
  vim.cmd("terminal " .. cmd)
  vim.cmd("startinsert")
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
    run_in_terminal(cmd)
  end)
end

local function add_reference(state, csproj_path)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  local sln = require("dotnet-tree.parser.sln").parse(state.dotnet_sln)
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
    local cmd = "dotnet add "
      .. vim.fn.shellescape(csproj_path)
      .. " reference "
      .. vim.fn.shellescape(choice.path)
    run_in_terminal(cmd)
  end)
end

function M.add(state)
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

  if kind == "packages" or kind == "package" then
    add_package(csproj_path)
  elseif kind == "projrefs" or kind == "project_reference" then
    add_reference(state, csproj_path)
  else
    vim.ui.select({ "package", "reference" }, { prompt = "Add to " .. proj_node.name .. ":" }, function(choice)
      if choice == "package" then
        add_package(csproj_path)
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

local function compute_namespace(target_dir, proj_path)
  local proj_dir = vim.fs.normalize(vim.fn.fnamemodify(proj_path, ":h"))
  local root_ns = vim.fn.fnamemodify(proj_path, ":t:r")
  local target = vim.fs.normalize(target_dir)
  local rel = target:sub(#proj_dir + 1):gsub("^/", "")
  if rel == "" then
    return root_ns
  end
  local parts = { root_ns }
  for part in rel:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return table.concat(parts, ".")
end

function M.new_file(state)
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
      local ns = compute_namespace(target_dir, proj_node.extra.project.path)
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

function M.build(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet build " .. vim.fn.shellescape(node.extra.project.path))
end

function M.run_project(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet run --project " .. vim.fn.shellescape(node.extra.project.path))
end

function M.build_solution(state)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet build " .. vim.fn.shellescape(state.dotnet_sln))
end

function M.clean(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet clean " .. vim.fn.shellescape(node.extra.project.path))
end

function M.clean_solution(state)
  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no solution loaded", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet clean " .. vim.fn.shellescape(state.dotnet_sln))
end

function M.test(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet test " .. vim.fn.shellescape(node.extra.project.path))
end

return M
