-- The git status markers (#49): `git status` runs in the background, never
-- inside tree.build, and the tree is told to rebuild only when the status it
-- shows is out of date. A git that fails keeps what is painted.

local git = require("dotnet-tree.git")

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

-- Stubs restored after each test, even when an assertion fails halfway.
local saved = {}
local function stub(tbl, key, value)
  table.insert(saved, { tbl = tbl, key = key, value = tbl[key] })
  tbl[key] = value
end

-- A throwaway repository with one committed file and nothing else, so the
-- status starts empty. Signing and hooks from the global config are turned
-- off: they are not what is under test.
local function repository()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
  local function sh(cmd)
    local full = { "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C", dir }
    vim.fn.system(vim.list_extend(full, cmd))
    assert.are.equal(0, vim.v.shell_error, table.concat(cmd, " "))
  end
  sh({ "init", "-q" })
  sh({ "config", "user.email", "test@example.com" })
  sh({ "config", "user.name", "test" })
  vim.fn.writefile({ "one" }, dir .. "/Kept.cs")
  sh({ "add", "Kept.cs" })
  sh({ "commit", "-q", "-m", "init" })
  return dir
end

-- Fetch and wait for it to end. Returns whether on_change was called.
local function fetch(dir)
  local changed = false
  git.fetch(dir, function()
    changed = true
  end)
  local done = vim.wait(5000, function()
    return not git._running(dir)
  end, 10)
  assert.is_true(done, "git did not answer")
  return changed
end

-- A jobstart that records each command and lets the test answer it.
local function fake_jobs()
  local jobs = {}
  stub(vim.fn, "jobstart", function(cmd, opts)
    table.insert(jobs, { cmd = cmd, opts = opts })
    return #jobs
  end)
  local function answer(i, code, stdout, stderr)
    assert.is_not_nil(jobs[i], "job " .. i .. " was never started")
    jobs[i].opts.on_stdout(i, stdout or {})
    jobs[i].opts.on_stderr(i, stderr or {})
    jobs[i].opts.on_exit(i, code)
    vim.wait(50, function()
      return false
    end, 5)
  end
  return jobs, answer
end

local function file_item(path)
  return { id = path, name = vim.fs.basename(path), type = "file", path = path, extra = { kind = "file" } }
end

local function painted(root, ...)
  local items = vim.tbl_map(file_item, { ... })
  git.apply_to_tree(items, root)
  return vim.tbl_map(function(item)
    return item.extra.git_status or false
  end, items)
end

describe("git status", function()
  local warnings

  before_each(function()
    git.reset()
    warnings = {}
    stub(vim, "notify", function(msg)
      table.insert(warnings, msg)
    end)
    -- Set when the suite runs from a git hook; they would point every
    -- command at the outer repository.
    for _, name in ipairs({ "GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE" }) do
      stub(vim.env, name, nil)
    end
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      saved[i].tbl[saved[i].key] = saved[i].value
    end
    saved = {}
    git.timeout_ms = 30000
  end)

  it("parses porcelain paths against the top level, renames and quoted names", function()
    local map = git.parse({ " M src/A.cs", "?? new file.cs", 'R  old.cs -> "renamed one.cs"' }, "/repo")
    assert.are.same({
      ["/repo/src/A.cs"] = " M",
      ["/repo/new file.cs"] = "??",
      ["/repo/renamed one.cs"] = "R ",
    }, map)
  end)

  it("never runs git while the tree is built", function()
    local started = 0
    local function count()
      started = started + 1
      return 1
    end
    stub(vim.fn, "jobstart", count)
    stub(vim.fn, "system", count)
    stub(vim.fn, "systemlist", count)
    local items = require("dotnet-tree.tree").build(FIXTURES .. "/Sample.slnx")
    assert.is_table(items)
    assert.are.equal(0, started)
  end)

  it("paints the status git reported, once it has answered", function()
    local dir = repository()
    vim.fn.writefile({ "two" }, dir .. "/Kept.cs")
    vim.fn.writefile({ "new" }, dir .. "/Added.cs")

    assert.are.same({ false, false }, painted(dir, dir .. "/Kept.cs", dir .. "/Added.cs"))
    assert.is_true(fetch(dir))
    assert.are.same({ " M", "??" }, painted(dir, dir .. "/Kept.cs", dir .. "/Added.cs"))
  end)

  it("asks for a rebuild only when the status changed", function()
    local dir = repository()
    assert.is_false(fetch(dir), "a clean repository changes nothing on screen")

    vim.fn.writefile({ "two" }, dir .. "/Kept.cs")
    assert.is_true(fetch(dir))
    assert.is_false(fetch(dir), "the same status again")
  end)

  it("paints nothing outside a repository, and does not ask git again", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    assert.is_false(fetch(dir))
    assert.are.same({}, warnings, "not being a repository is not a failure")

    local jobs = fake_jobs()
    fetch(dir)
    assert.are.same({}, jobs)
  end)

  it("keeps the markers when git status fails, and warns once", function()
    local jobs, answer = fake_jobs()
    git.fetch("/repo", function() end)
    answer(1, 0, { "/repo" })
    answer(2, 0, { " M A.cs" })
    assert.are.same({ " M" }, painted("/repo", "/repo/A.cs"))

    local changed = false
    for i = 1, 2 do
      git.fetch("/repo", function()
        changed = true
      end)
      answer(#jobs, 128, {}, { "fatal: index file corrupt" })
      assert.is_false(git._running("/repo"), "fetch " .. i .. " ended")
    end
    assert.is_false(changed, "a failed status is not a clean repository")
    assert.are.same({ " M" }, painted("/repo", "/repo/A.cs"))
    assert.are.equal(1, #warnings)
    assert.matches("index file corrupt", warnings[1])
  end)

  it("asks again next time when git fails for a reason other than 'not a repository'", function()
    local jobs, answer = fake_jobs()
    git.fetch("/repo")
    answer(1, 128, {}, { "fatal: detected dubious ownership in repository at '/repo'" })
    assert.is_false(git._running("/repo"))
    assert.matches("dubious ownership", warnings[1])

    git.fetch("/repo")
    assert.are.equal(2, #jobs, "rev-parse runs again: the cause may have been fixed")
    assert.are.same({ "git", "-C", "/repo", "rev-parse", "--show-toplevel" }, jobs[2].cmd)
  end)

  it("says nothing about a git stopped because Neovim is quitting", function()
    local _, answer = fake_jobs()
    git.fetch("/repo")
    stub(git, "exiting", function()
      return true
    end)
    answer(1, 143)
    assert.is_false(git._running("/repo"))
    assert.are.same({}, warnings)
  end)

  it("ends the fetch when git cannot start", function()
    stub(vim.fn, "jobstart", function()
      return -1
    end)
    assert.is_false(fetch("/repo"))
    assert.are.equal(1, #warnings)
    assert.matches("not executable", warnings[1])
  end)

  it("stops a git that never answers", function()
    local stopped = {}
    fake_jobs()
    stub(vim.fn, "jobstop", function(job)
      table.insert(stopped, job)
      return 1
    end)
    git.timeout_ms = 30
    git.fetch("/repo")
    assert.is_true(vim.wait(1000, function()
      return not git._running("/repo")
    end, 10))
    assert.are.same({ 1 }, stopped)
    assert.matches("no answer", warnings[1])
  end)

  it("ends the fetch when a callback throws, so later fetches still run", function()
    local jobs, answer = fake_jobs()
    stub(git, "parse", function()
      error("boom")
    end)
    git.fetch("/repo")
    answer(1, 0, { "/repo" })
    answer(2, 0, { " M A.cs" })
    assert.is_false(git._running("/repo"))
    assert.matches("boom", warnings[1])

    git.fetch("/repo")
    assert.are.equal(3, #jobs)
  end)

  it("asks again when a fetch is requested while one is running, with the latest callback", function()
    local jobs, answer = fake_jobs()
    local first, second = 0, 0
    git.fetch("/repo", function()
      first = first + 1
    end)
    answer(1, 0, { "/repo" }) -- rev-parse
    git.fetch("/repo", function() -- while `git status` is running
      second = second + 1
    end)
    answer(2, 0, { " M stale.cs" })
    assert.are.equal(3, #jobs, "the second request starts another git status")
    assert.are.equal(0, first + second, "the stale answer is not painted")
    answer(3, 0, { " M fresh.cs" })

    assert.are.same({ 0, 1 }, { first, second })
    assert.are.same({ " M", false }, painted("/repo", "/repo/fresh.cs", "/repo/stale.cs"))
  end)
end)
