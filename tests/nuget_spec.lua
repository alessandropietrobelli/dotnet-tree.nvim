local integration = require("dotnet-tree.nuget")

describe("nuget.nvim integration", function()
  local calls

  local function install_stub()
    calls = {}
    package.loaded["nuget"] = {
      open = function(opts)
        table.insert(calls, opts)
      end,
    }
  end

  after_each(function()
    package.loaded["nuget"] = nil
  end)

  it("does nothing when nuget.nvim is not installed", function()
    assert.is_nil(integration.module())
    assert.is_false(integration.open("packages", { project = "/repo/Api/Api.csproj" }))
  end)

  it("opens Browse with the project picked, from the Packages node", function()
    install_stub()
    assert.is_true(integration.open("packages", { project = "/repo/Api/Api.csproj", solution = "/repo/App.sln" }))
    assert.same({ { tab = "browse", project = "/repo/Api/Api.csproj", solution = "/repo/App.sln" } }, calls)
  end)

  it("opens on the package, from a package node", function()
    install_stub()
    integration.open("package", { project = "/repo/Api/Api.csproj", solution = "/repo/App.sln", package = "Serilog" })
    assert.same({ { package = "Serilog", project = "/repo/Api/Api.csproj", solution = "/repo/App.sln" } }, calls)
  end)

  it("falls back to Browse for a package node without a package", function()
    install_stub()
    integration.open("package", { project = "/repo/Api/Api.csproj" })
    assert.equals("browse", calls[1].tab)
  end)

  it("reloads the tree after nuget.nvim changes packages", function()
    local invalidated = {}
    local originals = {}
    for _, name in ipairs({ "csproj", "cpm", "props" }) do
      local mod = require("dotnet-tree.parser." .. name)
      originals[name] = mod.invalidate
      mod.invalidate = function(path)
        -- nil: the whole cache, since any project may have changed
        table.insert(invalidated, name .. ":" .. tostring(path))
      end
    end
    local refreshed = 0
    local group = vim.api.nvim_create_augroup("DotnetTreeNugetTest", { clear = true })
    integration.watch(group, function()
      refreshed = refreshed + 1
    end)

    vim.api.nvim_exec_autocmds("User", { pattern = "NugetPackagesChanged", data = { target = "/repo/App.sln" } })

    vim.api.nvim_del_augroup_by_id(group)
    for name, fn in pairs(originals) do
      require("dotnet-tree.parser." .. name).invalidate = fn
    end
    assert.equals(1, refreshed)
    table.sort(invalidated)
    assert.same({ "cpm:nil", "csproj:nil", "props:nil" }, invalidated)
  end)
end)
