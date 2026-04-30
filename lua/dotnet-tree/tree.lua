local sln_parser = require("dotnet-tree.parser.sln")
local csproj_parser = require("dotnet-tree.parser.csproj")

local M = {}

local IGNORED_DIRS = { bin = true, obj = true, [".vs"] = true, [".git"] = true, node_modules = true }

local function walk_dir(dir)
  local items = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return items
  end

  local entries = {}
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if not IGNORED_DIRS[name] then
      table.insert(entries, { name = name, type = ftype })
    end
  end

  table.sort(entries, function(a, b)
    if a.type ~= b.type then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)

  for _, e in ipairs(entries) do
    local path = dir .. "/" .. e.name
    if e.type == "directory" then
      table.insert(items, {
        id = "dotnet:dir:" .. path,
        name = e.name,
        type = "directory",
        path = path,
        extra = { kind = "folder" },
        children = walk_dir(path),
      })
    else
      table.insert(items, {
        id = path,
        name = e.name,
        type = "file",
        path = path,
        extra = { kind = "file" },
      })
    end
  end
  return items
end

local function build_project_node(proj)
  local children = {}
  local csproj = proj.path and csproj_parser.parse(proj.path) or nil

  if csproj then
    local deps_children = {}

    if #csproj.target_frameworks > 0 then
      local tf_children = {}
      for _, tf in ipairs(csproj.target_frameworks) do
        table.insert(tf_children, {
          id = "dotnet:tf:" .. proj.guid .. ":" .. tf,
          name = tf,
          type = "file",
          extra = { kind = "framework" },
        })
      end
      table.insert(deps_children, {
        id = "dotnet:frameworks:" .. proj.guid,
        name = "Frameworks",
        type = "directory",
        extra = { kind = "frameworks" },
        children = tf_children,
      })
    end

    if #csproj.project_references > 0 then
      local pref_children = {}
      table.sort(csproj.project_references, function(a, b)
        return a.path:lower() < b.path:lower()
      end)
      for _, pref in ipairs(csproj.project_references) do
        local pname = vim.fn.fnamemodify(pref.path, ":t:r")
        table.insert(pref_children, {
          id = "dotnet:pref:" .. proj.guid .. ":" .. pref.path,
          name = pname,
          type = "file",
          path = pref.path,
          extra = { kind = "project_reference" },
        })
      end
      table.insert(deps_children, {
        id = "dotnet:projrefs:" .. proj.guid,
        name = "Projects",
        type = "directory",
        extra = { kind = "projrefs" },
        children = pref_children,
      })
    end

    if #csproj.packages > 0 then
      local pkg_children = {}
      table.sort(csproj.packages, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      for _, pkg in ipairs(csproj.packages) do
        local label = pkg.version ~= "" and (pkg.name .. "  " .. pkg.version) or pkg.name
        table.insert(pkg_children, {
          id = "dotnet:pkg:" .. proj.guid .. ":" .. pkg.name,
          name = label,
          type = "file",
          extra = { kind = "package", package = pkg },
        })
      end
      table.insert(deps_children, {
        id = "dotnet:packages:" .. proj.guid,
        name = "Packages",
        type = "directory",
        extra = { kind = "packages" },
        children = pkg_children,
      })
    end

    if #deps_children > 0 then
      table.insert(children, {
        id = "dotnet:deps:" .. proj.guid,
        name = "Dependencies",
        type = "directory",
        extra = { kind = "dependencies" },
        children = deps_children,
      })
    end

    for _, item in ipairs(walk_dir(csproj.dir)) do
      table.insert(children, item)
    end
  end

  return {
    id = "dotnet:proj:" .. proj.guid,
    name = proj.name,
    type = "directory",
    path = proj.path,
    extra = { kind = "project", project = proj },
    children = children,
  }
end

local function make_solution_item_node(item, owner_guid)
  return {
    id = "dotnet:slnitem:" .. owner_guid .. ":" .. item.path,
    name = vim.fn.fnamemodify(item.path, ":t"),
    type = "file",
    path = item.path,
    extra = { kind = "file" },
  }
end

local function build_folder_node(folder, sln)
  local children = {}
  if folder.solution_items then
    for _, item in ipairs(folder.solution_items) do
      table.insert(children, make_solution_item_node(item, folder.guid))
    end
  end
  for _, child_guid in ipairs(folder.children_guids) do
    local child = sln.by_guid[child_guid]
    if child then
      local node
      if child.kind == "folder" then
        node = build_folder_node(child, sln)
      else
        node = build_project_node(child)
      end
      if node then
        table.insert(children, node)
      end
    end
  end
  local order = { sln_folder = 1, project = 2, file = 3 }
  table.sort(children, function(a, b)
    local ao, bo = order[a.extra.kind] or 9, order[b.extra.kind] or 9
    if ao ~= bo then
      return ao < bo
    end
    return a.name:lower() < b.name:lower()
  end)
  return {
    id = "dotnet:slnfolder:" .. folder.guid,
    name = folder.name,
    type = "directory",
    extra = { kind = "sln_folder" },
    children = children,
  }
end

function M.build(sln_path)
  local sln, err = sln_parser.parse(sln_path)
  if not sln then
    return nil, err
  end

  local roots = {}
  for _, proj in ipairs(sln.projects) do
    if not proj.parent_guid then
      local node
      if proj.kind == "folder" then
        node = build_folder_node(proj, sln)
      else
        node = build_project_node(proj)
      end
      if node then
        table.insert(roots, node)
      end
    end
  end

  table.sort(roots, function(a, b)
    local ak, bk = a.extra.kind, b.extra.kind
    if ak ~= bk then
      return ak == "sln_folder"
    end
    return a.name:lower() < b.name:lower()
  end)

  return {
    {
      id = "dotnet:sln:" .. sln_path,
      name = sln.name,
      type = "directory",
      path = sln_path,
      extra = { kind = "solution", sln = sln },
      children = roots,
    },
  }
end

return M
