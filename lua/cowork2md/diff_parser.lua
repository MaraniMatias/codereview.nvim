local M = {}

-- Parse a unified diff string into structured hunks
-- Returns: { hunks = { { header, lines = { {type, content, old_lnum, new_lnum} } } } }
function M.parse(diff_text)
  local result = { hunks = {} }
  local current_hunk = nil
  local old_lnum = 0
  local new_lnum = 0

  for line in (diff_text .. "\n"):gmatch("([^\n]*)\n") do
    -- Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
    local old_start, new_start = line:match("^@@ %-(%d+)[,%d]* %+(%d+)[,%d]* @@")
    if old_start then
      current_hunk = {
        header = line,
        lines = {},
        old_start = tonumber(old_start),
        new_start = tonumber(new_start),
      }
      table.insert(result.hunks, current_hunk)
      old_lnum = tonumber(old_start)
      new_lnum = tonumber(new_start)
    elseif current_hunk then
      if line:sub(1, 1) == "+" then
        table.insert(current_hunk.lines, {
          type = "add",
          content = line:sub(2),
          old_lnum = nil,
          new_lnum = new_lnum,
        })
        new_lnum = new_lnum + 1
      elseif line:sub(1, 1) == "-" then
        table.insert(current_hunk.lines, {
          type = "del",
          content = line:sub(2),
          old_lnum = old_lnum,
          new_lnum = nil,
        })
        old_lnum = old_lnum + 1
      elseif line:sub(1, 1) == " " then
        table.insert(current_hunk.lines, {
          type = "ctx",
          content = line:sub(2),
          old_lnum = old_lnum,
          new_lnum = new_lnum,
        })
        old_lnum = old_lnum + 1
        new_lnum = new_lnum + 1
      end
    end
  end

  return result
end

-- Get the content lines for display (with leading +/-/ )
-- Returns lines table and line-to-type mapping for highlights
function M.get_display_lines(parsed)
  local lines = {}
  local line_types = {}  -- "add", "del", "ctx", "hdr"

  for _, hunk in ipairs(parsed.hunks) do
    table.insert(lines, hunk.header)
    table.insert(line_types, "hdr")
    for _, l in ipairs(hunk.lines) do
      local prefix = l.type == "add" and "+" or l.type == "del" and "-" or " "
      table.insert(lines, prefix .. l.content)
      table.insert(line_types, l.type)
    end
  end

  return lines, line_types
end

return M
