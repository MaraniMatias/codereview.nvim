-- Tests for codereview.ui.explorer.model
-- Covers: header counter, actions_by_line mapping, note expansion

local config = require("codereview.config")
local store  = require("codereview.notes.store")

-- model is loaded after its deps so our stubs are already in place when it
-- was first required. We patch the live module table directly.
local model = require("codereview.ui.explorer.model")

local function make_file(path, status, extra)
  local f = vim.tbl_extend("force", { path = path, status = status, expanded = false }, extra or {})
  return f
end

describe("explorer model – header", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = { note_truncate_len = 30, note_glyph = "⊳" }
    store.count_for_file = function() return 0 end
    store.get_for_file   = function() return {} end
  end)

  after_each(function()
    store.count_for_file = orig_count
    store.get_for_file   = orig_get
    config.options       = orig_opts
  end)

  it("shows plain header when file list is empty", function()
    local result = model.build({}, nil)
    assert.equals("CodeReview  (? help)", result.lines[1])
  end)

  it("shows [current/total] counter in header", function()
    local files = { make_file("a.lua", "M"), make_file("b.lua", "A") }
    local result = model.build(files, 1)
    assert.equals("CodeReview [1/2]  (? help)", result.lines[1])
  end)

  it("counter updates when current_file_idx changes", function()
    local files = { make_file("a.lua", "M"), make_file("b.lua", "A"), make_file("c.lua", "D") }
    local r1 = model.build(files, 2)
    local r2 = model.build(files, 3)
    assert.equals("CodeReview [2/3]  (? help)", r1.lines[1])
    assert.equals("CodeReview [3/3]  (? help)", r2.lines[1])
  end)

  it("shows [0/N] when current_file_idx is nil", function()
    local files = { make_file("a.lua", "M") }
    local result = model.build(files, nil)
    assert.equals("CodeReview [0/1]  (? help)", result.lines[1])
  end)
end)

describe("explorer model – actions_by_line", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = { note_truncate_len = 30, note_glyph = "⊳" }
    store.count_for_file = function() return 0 end
    store.get_for_file   = function() return {} end
  end)

  after_each(function()
    store.count_for_file = orig_count
    store.get_for_file   = orig_get
    config.options       = orig_opts
  end)

  it("line 1 has no action (header row)", function()
    local files = { make_file("a.lua", "M") }
    local result = model.build(files, 1)
    assert.is_nil(result.actions_by_line[1])
  end)

  it("maps file rows to type='file' actions with correct idx", function()
    local files = {
      make_file("a.lua", "M"),
      make_file("b.lua", "A"),
    }
    local result = model.build(files, 1)
    -- header is line 1, files start at line 2
    local a2 = result.actions_by_line[2]
    local a3 = result.actions_by_line[3]
    assert.is_not_nil(a2)
    assert.equals("file", a2.type)
    assert.equals(1, a2.idx)
    assert.is_not_nil(a3)
    assert.equals("file", a3.type)
    assert.equals(2, a3.idx)
  end)

  it("interleaves note rows under expanded file", function()
    store.count_for_file = function(path)
      return path == "a.lua" and 1 or 0
    end
    store.get_for_file = function(path)
      if path == "a.lua" then
        return { { text = "looks good", line_start = 5, side = "new" } }
      end
      return {}
    end

    local files = {
      make_file("a.lua", "M", { expanded = true }),
      make_file("b.lua", "A"),
    }
    local result = model.build(files, 1)

    -- line 2 → file a.lua
    assert.equals("file", result.actions_by_line[2].type)
    assert.equals(1, result.actions_by_line[2].idx)
    -- line 3 → note under a.lua
    assert.equals("note", result.actions_by_line[3].type)
    assert.equals("a.lua", result.actions_by_line[3].filepath)
    assert.equals(5, result.actions_by_line[3].line)
    -- line 4 → file b.lua
    assert.equals("file", result.actions_by_line[4].type)
    assert.equals(2, result.actions_by_line[4].idx)
  end)

  it("does not emit note rows when file is not expanded", function()
    store.count_for_file = function() return 2 end
    store.get_for_file   = function()
      return {
        { text = "note1", line_start = 1, side = "new" },
        { text = "note2", line_start = 2, side = "new" },
      }
    end

    local files = { make_file("a.lua", "M", { expanded = false }) }
    local result = model.build(files, 1)
    -- only header (line 1) + one file row (line 2), no note rows
    assert.equals(2, #result.lines)
    assert.is_nil(result.actions_by_line[3])
  end)

  it("marks renamed file with old_path -> new_path label", function()
    local files = {
      make_file("new.lua", "R", { old_path = "old.lua" }),
    }
    local result = model.build(files, 1)
    assert.truthy(result.lines[2]:find("old.lua", 1, true))
    assert.truthy(result.lines[2]:find("new.lua", 1, true))
  end)
end)

describe("explorer model – E02 dim_col guard", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = { note_truncate_len = 30, explorer_layout = "flat", note_glyph = "⊳" }
    store.count_for_file = function() return 0 end
    store.get_for_file   = function() return {} end
  end)

  after_each(function()
    store.count_for_file = orig_count
    store.get_for_file   = orig_get
    config.options       = orig_opts
  end)

  it("dim_by_line col_start is never negative for short filenames", function()
    -- Single-char filename in a directory
    local files = { make_file("d/x", "M") }
    local result = model.build(files, 1)
    for lnum, dim in pairs(result.dim_by_line) do
      assert.is_true(dim.col_start >= 0,
        "dim col_start at line " .. lnum .. " is negative: " .. dim.col_start)
      assert.is_true(dim.col_end >= dim.col_start,
        "dim col_end < col_start at line " .. lnum)
    end
  end)

  it("dim_by_line for root files shows './' indicator (E03)", function()
    local files = { make_file("x", "M") }
    local result = model.build(files, 1)
    -- E03: root files now get a "./" dim entry
    local dim = result.dim_by_line[2]
    assert.is_not_nil(dim, "root file should have a dim entry for './'")
    assert.is_true(dim.col_start >= 0)
    assert.is_true(dim.col_end > dim.col_start)
    -- The dim portion should contain "./"
    local line = result.lines[2]
    local dim_text = line:sub(dim.col_start + 1, dim.col_end)
    assert.truthy(dim_text:find("%./"), "dim region should contain './'")
  end)
end)
