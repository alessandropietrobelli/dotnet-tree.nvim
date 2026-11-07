-- neo-tree builds each rendered component from the global
-- `default_component_configs` entry for it, then lets the keys set on the
-- component in the source's renderer win. A key the source sets on a common
-- component therefore overrides what the user configured for every source.
describe("default renderers", function()
  local defaults

  before_each(function()
    package.loaded["dotnet-tree"] = nil
    defaults = require("dotnet-tree").default_config.renderers
  end)

  it("leave the indent component to default_component_configs (#46)", function()
    local seen = 0
    for kind, renderer in pairs(defaults) do
      for _, component in ipairs(renderer) do
        if component[1] == "indent" then
          seen = seen + 1
          assert.are.same({ "indent" }, component, kind .. " renderer overrides indent settings")
        end
      end
    end
    assert.is_true(seen > 0, "no indent component in the default renderers")
  end)
end)
