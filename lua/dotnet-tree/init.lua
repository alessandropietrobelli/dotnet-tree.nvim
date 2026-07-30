local M = {
  name = "dotnet-tree",
  display_name = " 󰘐 .NET ",
}

M.default_config = {
  window = {
    position = "left",
    width = 40,
    mappings = {
      ["<cr>"] = { "open", desc = "open" },
      ["<2-LeftMouse>"] = { "open", desc = "open" },
      ["o"] = { "open", desc = "open" },
      ["<space>"] = { "toggle_node", desc = "toggle node" },
      ["R"] = { "refresh", desc = "refresh tree" },
      ["z"] = { "close_all_nodes", desc = "close all" },
      ["Z"] = { "expand_all_nodes", desc = "expand all" },
      ["?"] = { "show_help", desc = "show help" },
      ["s"] = { "select_solution", desc = "[.NET] select solution" },
      ["e"] = { "edit_project_file", desc = "[.NET] edit .csproj" },
      ["a"] = { "add", desc = "[.NET] add package/reference" },
      ["n"] = { "new_file", desc = "[.NET] new file from template" },
      ["b"] = { "build", desc = "[.NET] build project" },
      ["B"] = { "build_solution", desc = "[.NET] build solution" },
      ["c"] = { "clean", desc = "[.NET] clean project" },
      ["C"] = { "clean_solution", desc = "[.NET] clean solution" },
      ["r"] = { "run_project", desc = "[.NET] run project" },
      ["t"] = { "test", desc = "[.NET] test project" },
      ["w"] = { "watch", desc = "[.NET] watch run/test/build" },
    },
  },
  renderers = {
    directory = {
      { "indent", with_expanders = false },
      { "icon" },
      { "name" },
      { "diagnostics" },
      { "git_status" },
    },
    file = {
      { "indent", with_expanders = false },
      { "icon" },
      { "name" },
      { "diagnostics" },
      { "git_status" },
    },
  },
}

local function find_default_sln(cwd)
  return require("dotnet-tree.parser.solution").find(cwd)[1]
end

local function refresh_preserve_focus()
  local prev_win = vim.api.nvim_get_current_win()
  pcall(function()
    require("neo-tree.sources.manager").refresh("dotnet-tree")
  end)
  if vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

function M.setup(_, _)
  local group = vim.api.nvim_create_augroup("DotnetTreeAutoRefresh", { clear = true })

  local diag_pending = false
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function()
      if diag_pending then
        return
      end
      diag_pending = true
      vim.defer_fn(function()
        diag_pending = false
        refresh_preserve_focus()
      end, 800)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.csproj", "*.fsproj", "*.vbproj", "*.sln", "*.slnx", "Directory.Packages.props" },
    callback = function(args)
      local path = vim.fs.normalize(args.file)
      if path:match("%.slnx?$") then
        require("dotnet-tree.parser.solution").invalidate(path)
        require("dotnet-tree.parser.csproj").invalidate()
      elseif path:match("Directory%.Packages%.props$") then
        require("dotnet-tree.parser.cpm").invalidate(path)
      else
        require("dotnet-tree.parser.csproj").invalidate(path)
      end
      refresh_preserve_focus()
    end,
  })
end

function M.navigate(state, path, path_to_reveal, callback, async)
  local renderer = require("neo-tree.ui.renderer")
  state.path = state.path or vim.fn.getcwd()

  if not state.dotnet_sln then
    local persisted = require("dotnet-tree.store").get(state.path)
    if persisted and vim.fn.filereadable(persisted) == 1 then
      state.dotnet_sln = persisted
    else
      state.dotnet_sln = find_default_sln(state.path)
    end
  end

  if not state.dotnet_sln then
    vim.notify("[dotnet-tree] no .sln/.slnx found under " .. state.path, vim.log.levels.WARN)
    renderer.show_nodes({}, state)
    if callback then
      callback()
    end
    return
  end

  local tree = require("dotnet-tree.tree")
  local items, err = tree.build(state.dotnet_sln)
  if not items then
    vim.notify("[dotnet-tree] " .. tostring(err), vim.log.levels.ERROR)
    renderer.show_nodes({}, state)
    if callback then
      callback()
    end
    return
  end

  renderer.show_nodes(items, state)

  if path_to_reveal then
    pcall(renderer.focus_node, state, path_to_reveal)
  end

  if callback then
    callback()
  end
end

return M
