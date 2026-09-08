-- Errorformat tests for dotnet-tree.build.
--
-- This is the check that most needs writing carefully, because the failure mode
-- is silent: a pattern that stops matching produces zero quickfix entries, and
-- zero entries is indistinguishable from a clean build. So nothing here asserts
-- that setqflist survived the call. Every case asserts the entries it expects --
-- file, line, column, severity, error code -- against output captured from a
-- real `dotnet build`, and fails when they are missing.
--
-- The fixtures under tests/fixtures/build/ are verbatim `dotnet build` output
-- (SDK 10.0.302, classic console logger, which is what a jobstart pipe gets),
-- with absolute paths rewritten to /home/dev/src and the local NuGet feed names
-- replaced by nuget.org. Nothing else was edited: the duplication between the
-- inline diagnostics and the `Build FAILED.` summary is what MSBuild prints.
--
-- Run with plenary:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/build"

local build = require("dotnet-tree.build")

-- What runtime/compiler/dotnet.vim ships. Used by one test below to keep the
-- extension honest: if the bundled format were enough, this module would not
-- need to carry its own.
local BUNDLED_ERRORFORMAT = "%E%f(%l\\,%c): %trror %m,%-G%.%#"

local function fixture(name)
  local lines = vim.fn.readfile(FIXTURES .. "/" .. name .. ".txt")
  assert.is_true(#lines > 0, "fixture is empty: " .. name)
  return lines
end

local function parse(name)
  return build.parse(fixture(name))
end

local function describe_item(item)
  return ("%s:%d:%d [%s] %s"):format(
    item.bufnr > 0 and vim.fn.bufname(item.bufnr) or "<no file>",
    item.lnum,
    item.col,
    item.type,
    item.text
  )
end

-- Asserts one entry exists with exactly these fields, and returns it. Reports
-- everything that was parsed when it does not, because "expected 1, got 0" on
-- its own says nothing about which pattern stopped matching.
local function assert_entry(items, expected)
  for _, item in ipairs(items) do
    local name = item.bufnr > 0 and vim.fn.bufname(item.bufnr) or ""
    if
      name == (expected.filename or "")
      and item.lnum == expected.lnum
      and item.col == expected.col
      and item.type == expected.type
      and item.text == expected.text
    then
      return item
    end
  end

  local seen = {}
  for _, item in ipairs(items) do
    table.insert(seen, "    " .. describe_item(item))
  end
  assert.is_true(
    false,
    ("no quickfix entry matched %s:%d:%d [%s] %s\n  parsed %d entries:\n%s"):format(
      expected.filename or "<no file>",
      expected.lnum,
      expected.col,
      expected.type,
      expected.text,
      #items,
      #seen > 0 and table.concat(seen, "\n") or "    (none)"
    )
  )
end

describe("build.parse", function()
  it("finds the compiler error and its warning, once each", function()
    local items = parse("compile-error")

    assert_entry(items, {
      filename = "/home/dev/src/A/Program.cs",
      lnum = 7,
      col = 22,
      type = "e",
      text = "CS0029: Cannot implicitly convert type 'string' to 'int'",
    })
    assert_entry(items, {
      filename = "/home/dev/src/A/Program.cs",
      lnum = 8,
      col = 13,
      type = "w",
      text = "CS0219: The variable 'unused' is assigned but its value is never used",
    })

    -- MSBuild printed both of these twice: inline, then again under
    -- `Build FAILED.`. Four lines in, two entries out.
    assert.are.equal(2, #items)

    local errors, warnings = build.counts(items)
    assert.are.equal(1, errors)
    assert.are.equal(1, warnings)
  end)

  it("finds a restore error, which carries no line or column", function()
    -- The case the bundled errorformat drops entirely, and the one with no
    -- other route to the user: no language server sees a failed restore, and a
    -- failed restore stops compilation before any CS error is reported.
    local items = parse("restore-error")

    assert_entry(items, {
      filename = "/home/dev/src/B/B.csproj",
      lnum = 0,
      col = 0,
      type = "e",
      text = "NU1101: Unable to find package Contoso.Nonexistent.Package. "
        .. "No packages exist with this id in source(s): nuget.org",
    })
    assert.are.equal(1, #items)
  end)

  it("would drop the restore error on Neovim's bundled dotnet errorformat", function()
    -- Guards the reason M.errorformat exists. If a future Neovim widens
    -- runtime/compiler/dotnet.vim to cover this shape, this test fails and the
    -- extra patterns can be reconsidered -- rather than being carried forever
    -- with no one remembering why.
    local parsed = vim.fn.getqflist({ lines = fixture("restore-error"), efm = BUNDLED_ERRORFORMAT })
    assert.are.equal(0, #parsed.items)

    -- ... while it does see a positioned compiler error, so the fixture is not
    -- simply unparseable.
    parsed = vim.fn.getqflist({ lines = fixture("compile-error"), efm = BUNDLED_ERRORFORMAT })
    assert.is_true(#parsed.items > 0)
  end)

  it("reports an MSBuild error against the project file that caused it", function()
    local items = parse("import-error")

    assert_entry(items, {
      filename = "/home/dev/src/E/E.csproj",
      lnum = 5,
      col = 3,
      type = "e",
      text = 'MSB4019: The imported project "/home/dev/src/E/NoSuch.props" was not found. '
        .. 'Confirm that the expression in the Import declaration "NoSuch.props", which evaluated to '
        .. '"NoSuch.props", is correct, and that the file exists on disk.',
    })
    assert.are.equal(1, #items)
  end)

  it("collapses one error reported once per target framework", function()
    -- Four identical lines -- twice per target framework, twice again in the
    -- summary -- all naming the same source position.
    local items = parse("multitarget-error")

    assert_entry(items, {
      filename = "/home/dev/src/C/Widget.cs",
      lnum = 5,
      col = 28,
      type = "e",
      text = "CS0029: Cannot implicitly convert type 'string' to 'int'",
    })
    assert.are.equal(1, #items)
  end)

  it("keeps a warning from a successful build without inventing an error", function()
    local items = parse("success-warning")

    assert_entry(items, {
      filename = "/home/dev/src/D/Ok.cs",
      lnum = 7,
      col = 13,
      type = "w",
      text = "CS0219: The variable 'unused' is assigned but its value is never used",
    })
    assert.are.equal(1, #items)

    -- The window opens on a failing exit code, never on warnings alone.
    local errors, warnings = build.counts(items)
    assert.are.equal(0, errors)
    assert.are.equal(1, warnings)
  end)

  it("keeps an engine-level error visible without a bogus destination", function()
    -- `MSBUILD : error MSB1009` names the engine, not a file. Jumping to it
    -- would open an empty buffer called MSBUILD, so the entry keeps the text
    -- and loses the destination.
    local items = parse("missing-project")

    local entry = assert_entry(items, {
      lnum = 0,
      col = 0,
      type = "e",
      text = "MSBUILD: MSB1009: Project file does not exist.",
    })
    assert.are.equal(0, entry.bufnr)
    assert.are.equal(1, #items)
  end)

  it("returns nothing for output with no diagnostics", function()
    assert.are.equal(0, #build.parse({}))
    assert.are.equal(0, #build.parse({
      "  Determining projects to restore...",
      "  Restored /home/dev/src/D/D.csproj (in 155 ms).",
      "  D -> /home/dev/src/D/bin/Debug/net8.0/D.dll",
      "",
      "Build succeeded.",
      "    0 Warning(s)",
      "    0 Error(s)",
    }))
  end)
end)

describe("build.build", function()
  it("refuses an action that is not build or clean", function()
    assert.has_error(function()
      build.build("/home/dev/src/A/A.csproj", { action = "run" })
    end)
  end)

  it("does not start a job without a path", function()
    assert.is_nil(build.build(nil))
    assert.is_nil(build.build(""))
  end)
end)
