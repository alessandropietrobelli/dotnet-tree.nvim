-- The git status markers (#49): `git status` runs in the background, never
-- inside tree.build, and the tree is told to rebuild only when the status it
-- shows is out of date.

local git = require("dotnet-tree.git")

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures"

-- A throwaway repository with one committed file and nothing else, so the
-- status starts empty.
local function repository()
  local dir = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
  local function sh(cmd)
    vim.fn.system(vim.list_extend({ "git", "-C", dir }, cmd))
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

-- Fetch and wait for git to answer. Returns whether on_change was called.
local function fetch(dir)
  local changed, done = false, false
  git.fetch(dir, function()
    changed = true
  end)
  -- Without a change there is no callback, so wait for the fetch to end.
  vim.wait(5000, function()
    done = not git._running(dir)
    return done
  end, 10)
  assert.is_true(done, "git did not answer")
  return changed
end

local function file_item(path)
  return { id = path, name = vim.fs.basename(path), type = "file", path = path, extra = { kind = "file" } }
end

describe("git status", function()
  before_each(function()
    git.reset()
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
    local previous = { jobstart = vim.fn.jobstart, system = vim.fn.system, systemlist = vim.fn.systemlist }
    local function count()
      started = started + 1
      return 1
    end
    vim.fn.jobstart, vim.fn.system, vim.fn.systemlist = count, count, count
    local items = require("dotnet-tree.tree").build(FIXTURES .. "/Sample.slnx")
    vim.fn.jobstart, vim.fn.system, vim.fn.systemlist = previous.jobstart, previous.system, previous.systemlist

    assert.is_table(items)
    assert.are.equal(0, started)
  end)

  it("paints the status git reported, once it has answered", function()
    local dir = repository()
    vim.fn.writefile({ "two" }, dir .. "/Kept.cs")
    vim.fn.writefile({ "new" }, dir .. "/Added.cs")

    local before = { file_item(dir .. "/Kept.cs"), file_item(dir .. "/Added.cs") }
    git.apply_to_tree(before, dir)
    assert.is_nil(before[1].extra.git_status, "nothing is known before git answers")

    assert.is_true(fetch(dir))

    local after = { file_item(dir .. "/Kept.cs"), file_item(dir .. "/Added.cs") }
    git.apply_to_tree(after, dir)
    assert.are.equal(" M", after[1].extra.git_status)
    assert.are.equal("??", after[2].extra.git_status)
  end)

  it("asks for a rebuild only when the status changed", function()
    local dir = repository()
    assert.is_false(fetch(dir), "a clean repository changes nothing on screen")

    vim.fn.writefile({ "two" }, dir .. "/Kept.cs")
    assert.is_true(fetch(dir))
    assert.is_false(fetch(dir), "the same status again")
  end)

  it("paints nothing outside a repository, and asks git where the repository is only once", function()
    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    assert.is_false(fetch(dir))

    local calls = {}
    local previous = vim.fn.jobstart
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(cmd, opts)
      table.insert(calls, cmd)
      return previous(cmd, opts)
    end
    fetch(dir)
    vim.fn.jobstart = previous
    assert.are.same({}, calls)
  end)

  it("asks again when a fetch is requested while one is running", function()
    local jobs = {}
    local previous = vim.fn.jobstart
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(cmd, opts)
      table.insert(jobs, { cmd = cmd, opts = opts })
      return #jobs
    end
    local function answer(i, lines)
      jobs[i].opts.on_stdout(i, lines)
      jobs[i].opts.on_exit(i, 0)
    end

    local changes = 0
    local function on_change()
      changes = changes + 1
    end
    git.fetch("/repo", on_change)
    answer(1, { "/repo" }) -- rev-parse
    vim.wait(100, function()
      return #jobs == 2
    end, 5)
    git.fetch("/repo", on_change) -- while `git status` is running
    answer(2, { " M stale.cs" })
    vim.wait(100, function()
      return #jobs == 3
    end, 5)
    assert.are.equal(3, #jobs, "the second request starts another git status")
    assert.are.equal(0, changes, "the stale answer is not painted")
    answer(3, { " M fresh.cs" })
    vim.wait(100, function()
      return changes > 0
    end, 5)
    vim.fn.jobstart = previous

    assert.are.equal(1, changes)
    local items = { file_item("/repo/fresh.cs"), file_item("/repo/stale.cs") }
    git.apply_to_tree(items, "/repo")
    assert.are.equal(" M", items[1].extra.git_status)
    assert.is_nil(items[2].extra.git_status)
  end)
end)
