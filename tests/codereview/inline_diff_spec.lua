local inline_diff = require("codereview.ui.diff_view.inline_diff")

describe("inline_diff.compute_ranges()", function()
  it("returns empty ranges for identical strings", function()
    local del_r, add_r = inline_diff.compute_ranges("hello world", "hello world")
    assert.equals(0, #del_r)
    assert.equals(0, #add_r)
  end)

  it("detects a single word change", function()
    local del_r, add_r = inline_diff.compute_ranges("local y = 2", "local y = 3")
    -- Only the last character differs
    assert.equals(1, #del_r)
    assert.equals(1, #add_r)
    -- Common prefix: "local y = " (10 chars), common suffix: "" (0 chars)
    assert.equals(10, del_r[1][1])
    assert.equals(11, del_r[1][2])
    assert.equals(10, add_r[1][1])
    assert.equals(11, add_r[1][2])
  end)

  it("detects prefix-only change", function()
    local del_r, add_r = inline_diff.compute_ranges("foo bar", "baz bar")
    -- Common suffix is " bar" (4 chars), no common prefix
    assert.equals(1, #del_r)
    assert.equals(0, del_r[1][1])
    assert.equals(3, del_r[1][2])
    assert.equals(1, #add_r)
    assert.equals(0, add_r[1][1])
    assert.equals(3, add_r[1][2])
  end)

  it("detects suffix-only change", function()
    local del_r, add_r = inline_diff.compute_ranges("hello world", "hello earth")
    -- Common prefix: "hello " (6 chars)
    -- Old suffix: "world" (5), new suffix: "earth" (5)
    -- Common suffix from end: "d" vs "h" -> no common suffix? Let's check:
    -- "world" vs "earth" byte by byte from end: d≠h -> suffix_len=0
    assert.equals(1, #del_r)
    assert.equals(6, del_r[1][1])
    assert.equals(11, del_r[1][2])
  end)

  it("handles completely different strings", function()
    local del_r, add_r = inline_diff.compute_ranges("abc", "xyz")
    assert.equals(1, #del_r)
    assert.equals(0, del_r[1][1])
    assert.equals(3, del_r[1][2])
    assert.equals(1, #add_r)
    assert.equals(0, add_r[1][1])
    assert.equals(3, add_r[1][2])
  end)

  it("handles empty old string (pure addition)", function()
    local del_r, add_r = inline_diff.compute_ranges("", "new content")
    assert.equals(0, #del_r)
    assert.equals(1, #add_r)
    assert.equals(0, add_r[1][1])
    assert.equals(11, add_r[1][2])
  end)

  it("handles empty new string (pure deletion)", function()
    local del_r, add_r = inline_diff.compute_ranges("old content", "")
    assert.equals(1, #del_r)
    assert.equals(0, del_r[1][1])
    assert.equals(11, del_r[1][2])
    assert.equals(0, #add_r)
  end)

  it("handles insertion in the middle", function()
    local del_r, add_r = inline_diff.compute_ranges("func(a, b)", "func(a, c, b)")
    -- prefix: "func(a, " (8), suffix: ", b)" (4) -> wait
    -- old: "func(a, b)" new: "func(a, c, b)"
    -- prefix: "func(a, " (8 chars match)
    -- suffix from end: ")" match, " b)" match -> old[-3..]="b)" new[-3..]="b)" match
    -- suffix_len: ) = match (1), b) = old[9]=b new[12]=b match (2), ", b)" old[7..]=", b)" new[9..]=", b)" (4)
    -- Wait, let me re-check: old="func(a, b)", new="func(a, c, b)"
    -- Byte from end: old[10]=')' new[13]=')' match -> suffix 1
    -- old[9]='b' new[12]='b' match -> suffix 2
    -- old[8]=' ' new[11]=' ' match -> suffix 3
    -- old[7]=',' new[10]=',' match -> suffix 4 (but max_suffix = min(10,13)-8 = 2)
    -- max_suffix = min_len - prefix_len = 10 - 8 = 2
    -- So suffix_len = 2: "b)"
    -- del range: [8, 8) = empty (old_mid = 8..8)
    -- add range: [8, 11) = "c, " (3 chars)
    assert.equals(0, #del_r)
    assert.equals(1, #add_r)
    assert.equals(8, add_r[1][1])
    assert.equals(11, add_r[1][2])
  end)
end)

describe("inline_diff.compute_for_display()", function()
  it("finds inline ranges in a unified diff display", function()
    local lines = {
      "--- a/foo.lua",
      "+++ b/foo.lua",
      "@@ -1,3 +1,3 @@",
      " local x = 1",
      "-local y = 2",
      "+local y = 3",
      " return x",
    }
    local line_types = {
      "file_hdr", "file_hdr", "hdr", "ctx", "del", "add", "ctx",
    }

    local result = inline_diff.compute_for_display(lines, line_types)

    -- Line 5 (del) and line 6 (add) should have inline highlights
    assert.is_not_nil(result[5])
    assert.is_not_nil(result[6])
    -- The changed part is "2" -> "3" at position 10+1(prefix)=11
    assert.equals(1, #result[5])
    assert.equals(1, #result[6])
  end)

  it("returns empty for non-adjacent del/add", function()
    local lines = {
      "-deleted line",
      " context line",
      "+added line",
    }
    local line_types = { "del", "ctx", "add" }

    local result = inline_diff.compute_for_display(lines, line_types)
    -- del at 1 has no adjacent add -> no inline highlight
    assert.is_nil(result[1])
    -- add at 3 is not preceded by del -> no inline highlight
    assert.is_nil(result[3])
  end)

  it("handles multiple paired del/add groups", function()
    local lines = {
      "-old line one",
      "-old line two",
      "+new line one",
      "+new line two",
    }
    local line_types = { "del", "del", "add", "add" }

    local result = inline_diff.compute_for_display(lines, line_types)
    -- Both pairs should have highlights
    assert.is_not_nil(result[1]) -- del 1 paired with add 1
    assert.is_not_nil(result[3]) -- add 1
    assert.is_not_nil(result[2]) -- del 2 paired with add 2
    assert.is_not_nil(result[4]) -- add 2
  end)
end)

describe("inline_diff.compute_for_split()", function()
  it("finds inline ranges when del/add are aligned", function()
    local old_lines = { "-local y = 2" }
    local old_types = { "del" }
    local new_lines = { "+local y = 3" }
    local new_types = { "add" }

    local old_hl, new_hl = inline_diff.compute_for_split(
      old_lines, old_types, new_lines, new_types
    )

    assert.is_not_nil(old_hl[1])
    assert.is_not_nil(new_hl[1])
  end)

  it("skips non-paired lines", function()
    local old_lines = { " context", "-deleted" }
    local old_types = { "ctx", "del" }
    local new_lines = { " context", "" }
    local new_types = { "ctx", "pad" }

    local old_hl, new_hl = inline_diff.compute_for_split(
      old_lines, old_types, new_lines, new_types
    )

    assert.is_nil(old_hl[1])
    assert.is_nil(old_hl[2])
    assert.is_nil(new_hl[1])
    assert.is_nil(new_hl[2])
  end)
end)
