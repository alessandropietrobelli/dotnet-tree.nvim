local terminal = require("dotnet-tree.terminal")

describe("terminal buffer names", function()
  after_each(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):find(terminal.prefix, 1, true) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it("names the project after its file, without the extension", function()
    assert.equals("Api", terminal.project_name("/repo/src/Api/Api.csproj"))
  end)

  it("names the buffer after what it runs", function()
    assert.equals("dotnet-tree://run Api", terminal.buffer_name("run Api"))
  end)

  it("keeps a statusline's tail readable", function()
    assert.equals("watch test Api.Tests", vim.fn.fnamemodify(terminal.buffer_name("watch test Api.Tests"), ":t"))
  end)

  it("numbers a second buffer for the same command", function()
    local first = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(first, terminal.buffer_name("run Api"))
    assert.equals("dotnet-tree://run Api (2)", terminal.buffer_name("run Api"))
    local second = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(second, terminal.buffer_name("run Api"))
    assert.equals("dotnet-tree://run Api (3)", terminal.buffer_name("run Api"))
  end)

  it("renames the terminal it opens, and the command keeps running", function()
    local buf = terminal.open("sleep 5", "run Api")
    assert.equals("dotnet-tree://run Api", vim.api.nvim_buf_get_name(buf))
    assert.equals("terminal", vim.bo[buf].buftype)
    assert.equals(-1, vim.fn.jobwait({ vim.bo[buf].channel }, 0)[1])
    vim.cmd("stopinsert")
  end)

  it("keeps the terminal out of a bufferline, and labels its own split", function()
    local buf = terminal.open("sleep 5", "watch run Api")
    vim.cmd("stopinsert")
    assert.is_false(vim.bo[buf].buflisted)
    assert.equals(" watch run Api", vim.wo[vim.fn.bufwinid(buf)].winbar)
  end)

  it("escapes % in the winbar", function()
    assert.equals(" add 100%%Pkg to Api", terminal.winbar("add 100%Pkg to Api"))
  end)
end)
