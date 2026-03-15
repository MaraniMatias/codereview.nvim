local parser = require("codereview.diff_parser")

local SAMPLE_DIFF = [[
--- a/src/foo.lua
+++ b/src/foo.lua
@@ -1,4 +1,5 @@
 local x = 1
-local y = 2
+local y = 3
+local z = 4
 return x
]]

describe("diff_parser.parse()", function()
  local parsed

  before_each(function()
    parsed = parser.parse(SAMPLE_DIFF)
  end)

  it("captures old_file", function()
    assert.equals("a/src/foo.lua", parsed.old_file)
  end)

  it("captures new_file", function()
    assert.equals("b/src/foo.lua", parsed.new_file)
  end)

  it("produces one hunk", function()
    assert.equals(1, #parsed.hunks)
  end)

  it("hunk has correct old_start and new_start", function()
    local hunk = parsed.hunks[1]
    assert.equals(1, hunk.old_start)
    assert.equals(1, hunk.new_start)
  end)

  it("classifies ctx lines", function()
    local hunk = parsed.hunks[1]
    local ctx_lines = {}
    for _, l in ipairs(hunk.lines) do
      if l.type == "ctx" then table.insert(ctx_lines, l) end
    end
    assert.is_true(#ctx_lines >= 1)
  end)

  it("classifies del lines", function()
    local hunk = parsed.hunks[1]
    local del_lines = {}
    for _, l in ipairs(hunk.lines) do
      if l.type == "del" then table.insert(del_lines, l) end
    end
    assert.equals(1, #del_lines)
  end)

  it("classifies add lines", function()
    local hunk = parsed.hunks[1]
    local add_lines = {}
    for _, l in ipairs(hunk.lines) do
      if l.type == "add" then table.insert(add_lines, l) end
    end
    assert.equals(2, #add_lines)
  end)

  it("del lines have new_lnum = nil", function()
    local hunk = parsed.hunks[1]
    for _, l in ipairs(hunk.lines) do
      if l.type == "del" then
        assert.equals(nil, l.new_lnum)
      end
    end
  end)

  it("add lines have non-nil new_lnum", function()
    local hunk = parsed.hunks[1]
    for _, l in ipairs(hunk.lines) do
      if l.type == "add" then
        assert.is_not_nil(l.new_lnum)
      end
    end
  end)
end)

describe("diff_parser.get_display_lines()", function()
  local parsed
  local lines, line_types

  before_each(function()
    parsed = parser.parse(SAMPLE_DIFF)
    lines, line_types = parser.get_display_lines(parsed)
  end)

  it("returns correct total count (2 file_hdr + 1 hdr + hunk lines)", function()
    -- 2 file_hdr + 1 hunk header + 5 content lines (2 ctx + 1 del + 2 add) = 8
    assert.equals(8, #lines)
    assert.equals(8, #line_types)
  end)

  it("first line type is file_hdr", function()
    assert.equals("file_hdr", line_types[1])
  end)

  it("second line type is file_hdr", function()
    assert.equals("file_hdr", line_types[2])
  end)
end)
