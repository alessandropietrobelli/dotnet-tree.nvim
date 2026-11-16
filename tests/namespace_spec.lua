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
end)
