-- The namespace `n` gives a new file, from the project's root namespace and the
-- folders below it.

local namespace = require("dotnet-tree.namespace")
local csproj = require("dotnet-tree.parser.csproj")
local props = require("dotnet-tree.parser.props")

local function project(dir, name, property_group)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name .. ".csproj"
  vim.fn.writefile({
    '<Project Sdk="Microsoft.NET.Sdk">',
    "  <PropertyGroup>",
    "    <TargetFramework>net9.0</TargetFramework>",
    property_group or "",
    "  </PropertyGroup>",
    "</Project>",
  }, path)
  return path
end

describe("namespace", function()
  local root

  before_each(function()
    csproj.invalidate()
    props.invalidate()
    root = vim.fn.tempname()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("uses the RootNamespace the project declares", function()
    local path = project(root .. "/src/Api", "Api", "<RootNamespace>Contoso.Shop.Api</RootNamespace>")
    assert.are.equal("Contoso.Shop.Api", namespace.for_dir(path, root .. "/src/Api"))
    assert.are.equal("Contoso.Shop.Api.Models.Orders", namespace.for_dir(path, root .. "/src/Api/Models/Orders"))
  end)

  it("uses the one Directory.Build.props sets, expanding the project's name", function()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      "<Project>",
      "  <PropertyGroup>",
      "    <RootNamespace>Contoso.$(MSBuildProjectName)</RootNamespace>",
      "  </PropertyGroup>",
      "</Project>",
    }, root .. "/Directory.Build.props")
    local path = project(root .. "/src/Api", "Api")
    assert.are.equal("Contoso.Api.Models", namespace.for_dir(path, root .. "/src/Api/Models"))
  end)

  it("lets the project's own win over the inherited one", function()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile(
      { "<Project><PropertyGroup><RootNamespace>Inherited</RootNamespace></PropertyGroup></Project>" },
      root .. "/Directory.Build.props"
    )
    local path = project(root .. "/src/Api", "Api", "<RootNamespace>Own</RootNamespace>")
    assert.are.equal("Own", namespace.for_dir(path, root .. "/src/Api"))
  end)

  -- Measured with `dotnet msbuild -getProperty:RootNamespace`: "My-App 2" gives
  -- "My-App_2", and AssemblyName does not change it
  it("falls back to MSBuild's default, the project's name", function()
    local path = project(root .. "/src/Api", "Api", "<AssemblyName>Other.Name</AssemblyName>")
    assert.are.equal("Api.Models", namespace.for_dir(path, root .. "/src/Api/Models"))
  end)

  it("falls back to the default for a value only MSBuild can expand", function()
    local path = project(root .. "/src/Api", "Api", "<RootNamespace>$(Company).Api</RootNamespace>")
    assert.are.equal("Api", namespace.for_dir(path, root .. "/src/Api"))
  end)

  -- What C# accepts, as Visual Studio and Rider write it
  it("turns names that are not identifiers into ones that are", function()
    local path = project(root .. "/My App", "My App")
    assert.are.equal("My_App._2024.Read_Models", namespace.for_dir(path, root .. "/My App/2024/Read-Models"))
  end)

  it("does not take a sibling folder sharing the name's start as the project's", function()
    local path = project(root .. "/src/Api", "Api")
    assert.are.equal("Api", namespace.for_dir(path, root .. "/src/ApiTests/Models"))
  end)

  it("keeps letters of other alphabets, and escapes C#'s reserved words", function()
    local path = project(root .. "/src/Api", "Api")
    assert.are.equal("Api.Società.@event", namespace.for_dir(path, root .. "/src/Api/Società/event"))
  end)

  it("expands $(AssemblyName)", function()
    local path = project(
      root .. "/src/Api",
      "Api",
      "<AssemblyName>Contoso.Api</AssemblyName><RootNamespace>$(AssemblyName)</RootNamespace>"
    )
    assert.are.equal("Contoso.Api.Models", namespace.for_dir(path, root .. "/src/Api/Models"))
  end)

  -- The frameworks come from the nearer file and the namespace from the one it
  -- imports: a change up there has to reach a project read before it
  it("sees a change to RootNamespace further up the Directory.Build.props chain", function()
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.writefile({
      "<Project>",
      "  <Import Project=\"$([MSBuild]::GetPathOfFileAbove('Directory.Build.props', '$(MSBuildThisFileDirectory)../'))\" />",
      "  <PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup>",
      "</Project>",
    }, root .. "/src/Directory.Build.props")
    vim.fn.writefile(
      { "<Project><PropertyGroup><RootNamespace>Top</RootNamespace></PropertyGroup></Project>" },
      root .. "/Directory.Build.props"
    )
    local path = project(root .. "/src/Api", "Api")
    assert.are.equal("Top", namespace.for_dir(path, root .. "/src/Api"))
    vim.fn.writefile(
      { "<Project><PropertyGroup><RootNamespace>Changed</RootNamespace></PropertyGroup></Project>" },
      root .. "/Directory.Build.props"
    )
    local later = os.time() + 5
    vim.uv.fs_utime(root .. "/Directory.Build.props", later, later)
    assert.are.equal("Changed", namespace.for_dir(path, root .. "/src/Api"))
  end)

  -- `n` through commands.lua: the file it writes
  it("writes it into the file n creates", function()
    local path = project(root .. "/src/Api", "Api", "<RootNamespace>Contoso.$(MSBuildProjectName)</RootNamespace>")
    vim.fn.mkdir(root .. "/src/Api/Models/Orders", "p")
    package.loaded["neo-tree.sources.common.commands"] = {}
    package.loaded["neo-tree.sources.manager"] = { refresh = function() end }
    package.loaded["dotnet-tree.commands"] = nil
    local commands = require("dotnet-tree.commands")
    local project_node = { name = "Api", extra = { kind = "project", project = { path = path } } }
    function project_node.get_parent_id() end
    local folder = { name = "Orders", path = root .. "/src/Api/Models/Orders", extra = { kind = "folder" } }
    function folder.get_parent_id()
      return "project"
    end
    local state = {
      tree = {
        get_node = function(_, id)
          return id == "project" and project_node or folder
        end,
      },
    }
    local select, input = vim.ui.select, vim.ui.input
    vim.ui.select = function(_, _, cb)
      cb("interface")
    end
    vim.ui.input = function(_, cb)
      cb("Repository")
    end
    local ok, err = pcall(commands.new_file, state)
    vim.ui.select, vim.ui.input = select, input
    package.loaded["neo-tree.sources.common.commands"] = nil
    package.loaded["neo-tree.sources.manager"] = nil
    package.loaded["dotnet-tree.commands"] = nil
    assert(ok, err)
    local written = vim.fn.readfile(root .. "/src/Api/Models/Orders/IRepository.cs")
    assert.are.equal("namespace Contoso.Api.Models.Orders;", written[1])
  end)
end)
