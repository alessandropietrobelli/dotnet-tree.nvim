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

function M.test(state)
  local node = find_project_node(state)
  if not node then
    vim.notify("[dotnet-tree] cursor not on a project", vim.log.levels.WARN)
    return
  end
  run_in_terminal("dotnet test " .. vim.fn.shellescape(node.extra.project.path))
end

return M
