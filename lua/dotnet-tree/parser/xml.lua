-- The XML reading that parser/slnx.lua has always done, moved here so the
-- .csproj and Directory.Packages.props readers can use it too.
--
-- It is deliberately minimal: enough to find where a tag really ends, read its
-- attributes, and build a lightweight element tree. It does not validate, does
-- not resolve namespaces and does not evaluate anything -- an MSBuild property
-- reference such as `Version="$(SerilogVersion)"` comes back verbatim, because
-- reading XML and evaluating MSBuild are different problems.
--
-- The rule that matters for the project files: a literal '>' is legal inside an
-- attribute value. XML 1.0 section 2.4 forbids '<' and '&' there, not '>', and
-- MSBuild builds such a project without a warning. A scanner that stops at the
-- first '>' truncates the tag and drops whatever follows -- silently.

local M = {}

local NAMED_ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

function M.unescape(s)
  if not s or s:find("&", 1, true) == nil then
    return s
  end
  s = s:gsub("&#x(%x+);", function(h)
    return vim.fn.nr2char(tonumber(h, 16))
  end)
  s = s:gsub("&#(%d+);", function(d)
    return vim.fn.nr2char(tonumber(d))
  end)
  s = s:gsub("&(%a+);", function(name)
    return NAMED_ENTITIES[name] or ("&" .. name .. ";")
  end)
  return s
end

function M.parse_attrs(str)
  local attrs = {}
  for k, v in str:gmatch('([%w_:%-%.]+)%s*=%s*"([^"]*)"') do
    attrs[k] = M.unescape(v)
  end
  for k, v in str:gmatch("([%w_:%-%.]+)%s*=%s*'([^']*)'") do
    if attrs[k] == nil then
      attrs[k] = M.unescape(v)
    end
  end
  return attrs
end

-- The Microsoft slnx reader matches element/attribute names case-insensitively
-- (it emits PascalCase but accepts any casing). Mirror that.
function M.attr_ci(attrs, key)
  if attrs[key] ~= nil then
    return attrs[key]
  end
  local lk = key:lower()
  for k, v in pairs(attrs) do
    if k:lower() == lk then
      return v
    end
  end
  return nil
end

-- Find the '>' that closes a tag, ignoring any '>' that sits inside a quoted
-- attribute value (a literal '>' is legal in XML attribute values).
function M.find_tag_end(content, from)
  local i, len = from, #content
  local quote = nil
  while i <= len do
    local c = content:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ">" then
      return i
    end
    i = i + 1
  end
  return nil
end

function M.strip_noise(content)
  content = content:gsub("^\239\187\191", "") -- strip UTF-8 BOM
  content = content:gsub("<!%-%-.-%-%->", "") -- comments
  content = content:gsub("<%?.-%?>", "") -- <?xml ... ?>
  content = content:gsub("<!%[CDATA%[.-%]%]>", "") -- CDATA
  content = content:gsub("<!.->", "") -- <!DOCTYPE ...>
  return content
end

-- Iterate the opening tags named `name`, quote-aware, in document order.
-- Yields the attribute text of each tag together with whether it was written
-- self-closing; the caller reads whatever attributes it cares about. Closing
-- tags are skipped. Comments are the caller's business: pass content that has
-- already been through `strip_noise` if they matter.
function M.iter_tags(content, name)
  local pos, len = 1, #content
  return function()
    while pos <= len do
      local lt = content:find("<", pos, true)
      if not lt then
        return nil
      end
      local gt = M.find_tag_end(content, lt + 1)
      if not gt then
        return nil
      end
      local raw = content:sub(lt + 1, gt - 1)
      pos = gt + 1
      local tag = raw:match("^([%w_:%-%.]+)")
      if tag == name then
        local attr_str = raw:sub(#tag + 1)
        return attr_str, attr_str:match("/%s*$") ~= nil
      end
    end
    return nil
  end
end

-- Build a lightweight element tree. Text nodes are ignored (the callers that
-- exist today carry their data in attributes). Tolerant of self-closing tags
-- (with or without spaces around the slash), comments, declarations, and '>'
-- inside attribute values.
function M.parse(content)
  content = M.strip_noise(content)

  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local pos, len = 1, #content

  while pos <= len do
    local lt = content:find("<", pos, true)
    if not lt then
      break
    end
    local gt = M.find_tag_end(content, lt + 1)
    if not gt then
      break
    end

    local raw = content:sub(lt + 1, gt - 1):gsub("^%s+", ""):gsub("%s+$", "")
    if raw:sub(1, 1) == "/" then
      if #stack > 1 then
        table.remove(stack)
      end
    elseif raw ~= "" then
      local self_closing = raw:sub(-1) == "/"
      if self_closing then
        raw = raw:gsub("/%s*$", "")
      end
      local name = raw:match("^([%w_:%-%.]+)")
      if name then
        local attr_str = raw:sub(#name + 1)
        local node = { tag = name, attrs = M.parse_attrs(attr_str), children = {} }
        table.insert(stack[#stack].children, node)
        if not self_closing then
          table.insert(stack, node)
        end
      end
    end
    pos = gt + 1
  end

  return root
end

return M
