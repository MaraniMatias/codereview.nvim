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

-- Default config stub for flat layout tests.
-- Includes all P3 options so the model doesn't error on missing keys.
local function flat_config()
  return {
    note_truncate_len = 30,
    note_glyph = "⊳",
    explorer_show_help = true,
    explorer_path_separator = "  ",
    explorer_status_icons = nil,
    note_count_hl = "WarningMsg",
    explorer_width = 30,
    explorer_layout = "flat",
  }
end

-- E11/E16: with P3, header is line 1, separator is line 2, files start at line 3.
-- E16: header now includes "[flat]" or "[tree]" layout tag.

describe("explorer model – header", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = flat_config()
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

  it("hides help hint when explorer_show_help is false (E06)", function()
    config.options.explorer_show_help = false
    local files = { make_file("a.lua", "M") }
    local result = model.build(files, 1)
    assert.equals("CodeReview [1/1]", result.lines[1])
  end)

  it("E11: has empty separator on line 2", function()
    local files = { make_file("a.lua", "M") }
    local result = model.build(files, 1)
    assert.equals("", result.lines[2])
  end)
end)

describe("explorer model – actions_by_line", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = flat_config()
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

  it("line 2 has no action (separator row)", function()
    local files = { make_file("a.lua", "M") }
    local result = model.build(files, 1)
    assert.is_nil(result.actions_by_line[2])
  end)

  it("maps file rows to type='file' actions with correct idx", function()
    local files = {
      make_file("a.lua", "M"),
      make_file("b.lua", "A"),
    }
    local result = model.build(files, 1)
    -- header is line 1, separator is line 2, files start at line 3
    local a3 = result.actions_by_line[3]
    local a4 = result.actions_by_line[4]
    assert.is_not_nil(a3)
    assert.equals("file", a3.type)
    assert.equals(1, a3.idx)
    assert.is_not_nil(a4)
    assert.equals("file", a4.type)
    assert.equals(2, a4.idx)
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

    -- line 3 → file a.lua (after header + separator)
    assert.equals("file", result.actions_by_line[3].type)
    assert.equals(1, result.actions_by_line[3].idx)
    -- line 4 → note under a.lua
    assert.equals("note", result.actions_by_line[4].type)
    assert.equals("a.lua", result.actions_by_line[4].filepath)
    assert.equals(5, result.actions_by_line[4].line)
    -- line 5 → file b.lua
    assert.equals("file", result.actions_by_line[5].type)
    assert.equals(2, result.actions_by_line[5].idx)
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
    -- header (1) + separator (2) + one file row (3), no note rows
    assert.equals(3, #result.lines)
    assert.is_nil(result.actions_by_line[4])
  end)

  it("marks renamed file with old_path -> new_path label", function()
    local files = {
      make_file("new.lua", "R", { old_path = "old.lua" }),
    }
    local result = model.build(files, 1)
    -- file is at line 3 (after header + separator)
    assert.truthy(result.lines[3]:find("old.lua", 1, true))
    assert.truthy(result.lines[3]:find("new.lua", 1, true))
  end)
end)

describe("explorer model – E02 dim_col guard", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = flat_config()
    config.options.explorer_layout = "flat"
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
    -- E03: root files now get a "./" dim entry (file is on line 3 after header + separator)
    local dim = result.dim_by_line[3]
    assert.is_not_nil(dim, "root file should have a dim entry for './'")
    assert.is_true(dim.col_start >= 0)
    assert.is_true(dim.col_end > dim.col_start)
    -- The dim portion should contain "./"
    local line = result.lines[3]
    local dim_text = line:sub(dim.col_start + 1, dim.col_end)
    assert.truthy(dim_text:find("%./"), "dim region should contain './'")
  end)
end)

describe("explorer model – E12 custom status icons", function()
  local orig_count, orig_get, orig_opts

  before_each(function()
    orig_count = store.count_for_file
    orig_get   = store.get_for_file
    orig_opts  = config.options
    config.options = flat_config()
    store.count_for_file = function() return 0 end
    store.get_for_file   = function() return {} end
  end)

  after_each(function()
    store.count_for_file = orig_count
    store.get_for_file   = orig_get
    config.options       = orig_opts
  end)

  it("uses custom status icons when configured", function()
    config.options.explorer_status_icons = { M = "~", A = "+" }
    local files = { make_file("a.lua", "M"), make_file("b.lua", "A") }
    local result = model.build(files, 1)
    -- line 3 (file a.lua) should contain "~" not "[M]"
    assert.truthy(result.lines[3]:find("~", 1, true))
    assert.falsy(result.lines[3]:find("%[M%]"))
    -- line 4 (file b.lua) should contain "+" not "[A]"
    assert.truthy(result.lines[4]:find("+", 1, true))
    assert.falsy(result.lines[4]:find("%[A%]"))
  end)
end)
