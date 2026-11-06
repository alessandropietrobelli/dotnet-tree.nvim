local M = {
  name = "dotnet-tree",
  display_name = " 󰘐 .NET ",
}

M.default_config = {
  -- Like the filesystem source's option: on every buffer switch, expand the
  -- tree down to the current file and put the cursor on it, keeping the focus
  -- in the editor. leave_dirs_open keeps the folders it opened on the way.
  follow_current_file = {
    enabled = false,
    leave_dirs_open = false,
  },
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
      ["d"] = { "debug", desc = "[.NET] debug project" },
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

-- follow_current_file runs on every buffer switch: an error there is logged
-- each time but shown once, rather than on every switch or never.
local follow_warned = false

local function on_buffer_enter()
  local ok, err = pcall(function()
    local manager = require("neo-tree.sources.manager")
    require("dotnet-tree.reveal").follow(manager.get_state(M.name), manager.get_path_to_reveal())
  end)
  if ok then
    return
  end
  pcall(function()
    require("neo-tree.log").debug("[dotnet-tree] follow_current_file failed: ", err)
  end)
  if not follow_warned then
    follow_warned = true
    vim.notify("[dotnet-tree] follow_current_file failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

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

function M.setup(config, _)
  local group = vim.api.nvim_create_augroup("DotnetTreeAutoRefresh", { clear = true })

  if config and config.follow_current_file and config.follow_current_file.enabled then
    require("neo-tree.sources.manager").subscribe(M.name, {
      event = require("neo-tree.events").VIM_BUFFER_ENTER,
      -- must not return true: neo-tree drops a handler that does
      handler = function()
        on_buffer_enter()
      end,
    })
  end

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

  -- nuget.nvim changes projects with dotnet, outside any buffer: BufWritePost never sees it
  require("dotnet-tree.nuget").watch(group, refresh_preserve_focus)
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

  local reveal = require("dotnet-tree.reveal")
  state.dotnet_index = reveal.index(items)
  renderer.show_nodes(items, state)

  -- node ids are not paths here, so `:Neotree reveal` goes through the index.
  -- A file no node shows is not an error: with follow_current_file every
  -- :Neotree is an implied reveal of whatever buffer is current.
  local reveal_id = reveal.lookup(state.dotnet_index, path_to_reveal)
  if reveal_id then
    local ok, err = pcall(reveal.focus, state, reveal_id)
    if not ok then
      vim.notify("[dotnet-tree] could not reveal " .. path_to_reveal .. ": " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  if callback then
    callback()
  end
end

return M
