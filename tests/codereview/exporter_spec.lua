local state    = require("codereview.state")
local store    = require("codereview.notes.store")
local config   = require("codereview.config")
local exporter = require("codereview.review.exporter")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function setup_format(fmt)
  config.setup({ review = { export_format = fmt } })
end

-- ---------------------------------------------------------------------------
-- Format-agnostic tests (run against the default "human" format)
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — common", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    config.setup({})
  end)

  it("returns a string starting with '# Code Review '", function()
    local out = exporter.generate()
    assert.truthy(out:match("^# Code Review %d%d%d%d%-%d%d%-%d%d"))
  end)

  it("returns placeholder text when there are no notes", function()
    local out = exporter.generate()
    assert.truthy(out:find("_Write your notes here._", 1, true))
  end)

  it("does not include placeholder when notes exist", function()
    store.set("src/foo.lua", 5, 5, "const x = 1", "revisar esto", "new")
    local out = exporter.generate()
    assert.falsy(out:find("_Write your notes here._", 1, true))
  end)

  it("includes the note text in the output", function()
    store.set("a.lua", 1, 1, "", "this is important", "new")
    local out = exporter.generate()
    assert.truthy(out:find("this is important", 1, true))
  end)

  it("emits notes sorted by filepath then line", function()
    store.set("z.lua", 1, 1, "", "note z",  "new")
    store.set("a.lua", 5, 5, "", "note a5", "new")
    store.set("a.lua", 2, 2, "", "note a2", "new")
    local out = exporter.generate()
    local pos_a2 = out:find("note a2", 1, true)
    local pos_a5 = out:find("note a5", 1, true)
    local pos_z  = out:find("note z",  1, true)
    assert.is_true(pos_a2 < pos_a5)
    assert.is_true(pos_a5 < pos_z)
  end)

  it("includes enriched header with diff context", function()
    state.get().diff_args = { "main..feature" }
    store.set("a.lua", 1, 1, "", "note a", "new")
    local out = exporter.generate()
    assert.truthy(out:find("`main..feature`", 1, true))
    assert.truthy(out:find("1 file", 1, true))
    assert.truthy(out:find("1 note", 1, true))
  end)

  it("header shows 'working tree' when diff_args is empty", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    local out = exporter.generate()
    assert.truthy(out:find("`working tree`", 1, true))
  end)

  it("header shows 'difftool' when mode is difftool", function()
    state.get().mode = "difftool"
    store.set("a.lua", 1, 1, "", "note a", "new")
    local out = exporter.generate()
    assert.truthy(out:find("`difftool`", 1, true))
  end)

  it("header counts multiple files and notes correctly", function()
    store.set("a.lua", 1, 1, "", "note 1", "new")
    store.set("a.lua", 5, 5, "", "note 2", "new")
    store.set("b.lua", 3, 3, "", "note 3", "new")
    local out = exporter.generate()
    assert.truthy(out:find("2 files", 1, true))
    assert.truthy(out:find("3 notes", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- "human" format
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — default format", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    setup_format("default")
  end)

  it("groups notes under ## heading per file", function()
    store.set("src/foo.lua", 5, 5, "", "some note", "new")
    local out = exporter.generate()
    assert.truthy(out:find("## src/foo.lua", 1, true))
  end)

  it("shows smart range L5 when start==end", function()
    store.set("a.lua", 5, 5, "", "single line", "new")
    local out = exporter.generate()
    assert.truthy(out:find("**L5**", 1, true))
    assert.falsy(out:find("**L5-5**", 1, true))
  end)

  it("shows range L7-9 when start!=end", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    assert.truthy(out:find("**L7-9**", 1, true))
  end)

  it("marks old-side notes with (old) instead of (deleted)", function()
    store.set("src/bar.lua", 10, 10, "", "deleted note", "old")
    local out = exporter.generate()
    assert.truthy(out:find("(old)", 1, true))
    assert.falsy(out:find("(deleted)", 1, true))
  end)

  it("uses language-specific code block fencing", function()
    store.set("app.js", 1, 1, "const x = 1", "check", "new")
    local out = exporter.generate()
    assert.truthy(out:find("```js", 1, true))
  end)

  it("detects lua language for .lua files", function()
    store.set("init.lua", 1, 1, "local M = {}", "check", "new")
    local out = exporter.generate()
    assert.truthy(out:find("```lua", 1, true))
  end)

  it("detects python language for .py files", function()
    store.set("main.py", 1, 1, "import os", "check", "new")
    local out = exporter.generate()
    assert.truthy(out:find("```python", 1, true))
  end)

  it("includes code block when code is provided", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    assert.truthy(out:find("```lua", 1, true))
    assert.truthy(out:find("local x = 1", 1, true))
  end)

  it("does not use old text{N,M} syntax", function()
    store.set("a.lua", 7, 9, "local x = 1", "check", "new")
    local out = exporter.generate()
    assert.falsy(out:find("```text{", 1, true))
  end)

  it("separates notes in the same file with ---", function()
    store.set("a.lua", 1, 1, "line1", "note 1", "new")
    store.set("a.lua", 5, 5, "line5", "note 2", "new")
    local out = exporter.generate()
    assert.truthy(out:find("---", 1, true))
  end)

  it("does not add --- after the last note in a file", function()
    store.set("a.lua", 1, 1, "line1", "note 1", "new")
    local out = exporter.generate()
    assert.falsy(out:find("---", 1, true))
  end)

  it("includes all notes from all files under separate headings", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    store.set("b.lua", 1, 1, "", "note b", "new")
    local out = exporter.generate()
    assert.truthy(out:find("## a.lua", 1, true))
    assert.truthy(out:find("## b.lua", 1, true))
    assert.truthy(out:find("note a", 1, true))
    assert.truthy(out:find("note b", 1, true))
  end)

  it("multiline note text appears line by line in output", function()
    store.set("a.lua", 1, 1, "", "line one\nline two\nline three", "new")
    local out = exporter.generate()
    assert.truthy(out:find("line one",   1, true))
    assert.truthy(out:find("line two",   1, true))
    assert.truthy(out:find("line three", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- "llm" format
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — table format", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    setup_format("table")
  end)

  it("starts with TSV header", function()
    local out = exporter.generate()
    assert.truthy(out:match("^file|line|text"))
  end)

  it("has only the header line when no notes exist", function()
    local out = exporter.generate()
    local line_count = 0
    for _ in out:gmatch("[^\n]+") do
      line_count = line_count + 1
    end
    assert.equals(1, line_count)
  end)

  it("includes pipe-separated fields for a note", function()
    store.set("src/foo.lua", 5, 8, "", "some note", "new")
    local out = exporter.generate()
    assert.truthy(out:find("src/foo.lua|5-8|some note", 1, true))
  end)

  it("uses smart range (no redundant 5-5)", function()
    store.set("a.lua", 5, 5, "", "single line", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua|5|", 1, true))
    assert.falsy(out:find("5-5", 1, true))
  end)

  it("shows range when start!=end", function()
    store.set("a.lua", 5, 10, "", "multi line", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua|5-10|", 1, true))
  end)

  it("marks old-side notes with (del) suffix on filepath", function()
    store.set("src/bar.lua", 10, 12, "", "old note", "old")
    local out = exporter.generate()
    assert.truthy(out:find("src/bar.lua (del)|10-12|old note", 1, true))
  end)

  it("does not add (del) suffix for new-side notes", function()
    store.set("src/bar.lua", 10, 12, "", "new note", "new")
    local out = exporter.generate()
    assert.falsy(out:find("(del)", 1, true))
    assert.truthy(out:find("src/bar.lua|10-12|new note", 1, true))
  end)

  it("collapses multiline note to a single line", function()
    store.set("a.lua", 1, 1, "", "line one\nline two", "new")
    local out = exporter.generate()
    assert.truthy(out:find("line one line two", 1, true))
    assert.falsy(out:match("line one\nline two"))
  end)

  it("does not include code blocks or markdown formatting", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    assert.falsy(out:find("```", 1, true))
    assert.falsy(out:find("##", 1, true))
    assert.falsy(out:find("**", 1, true))
  end)

  it("includes all notes from all files", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    store.set("b.lua", 3, 5, "", "note b", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua|1|note a",   1, true))
    assert.truthy(out:find("b.lua|3-5|note b", 1, true))
  end)
end)
