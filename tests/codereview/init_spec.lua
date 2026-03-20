local cr = require("codereview")

describe("_build_file_summary()", function()
  it("shows only changed when no untracked files", function()
    local files = {
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "A" },
      { path = "c.lua", status = "D" },
    }
    assert.equals("3 changed file(s)", cr._build_file_summary(files))
  end)

  it("shows only untracked when no changed files", function()
    local files = {
      { path = "x.lua", status = "?" },
      { path = "y.lua", status = "?" },
    }
    assert.equals("2 untracked file(s)", cr._build_file_summary(files))
  end)

  it("shows both changed and untracked", function()
    local files = {
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "A" },
      { path = "x.lua", status = "?" },
    }
    assert.equals("2 changed + 1 untracked file(s)", cr._build_file_summary(files))
  end)

  it("returns summary for empty file list", function()
    assert.equals("0 file(s)", cr._build_file_summary({}))
  end)

  it("treats rename status as changed", function()
    local files = {
      { path = "new.lua", old_path = "old.lua", status = "R" },
      { path = "u.lua", status = "?" },
    }
    assert.equals("1 changed + 1 untracked file(s)", cr._build_file_summary(files))
  end)
end)
