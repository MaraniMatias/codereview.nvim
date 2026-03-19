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
-- Format-agnostic tests (run against the default format)
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — common", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    config.setup({})
  end)

  it("returns a string starting with '# Review '", function()
    local out = exporter.generate()
    assert.truthy(out:match("^# Review %d%d%d%d%-%d%d%-%d%d"))
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
end)

-- ---------------------------------------------------------------------------
-- "block" format (original behaviour)
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — block format", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    setup_format("block")
  end)

  it("includes the filepath as inline code anchor", function()
    store.set("src/foo.lua", 5, 5, "", "some note", "new")
    local out = exporter.generate()
    assert.truthy(out:find("`src/foo.lua`", 1, true))
  end)

  it("marks old-side notes with '(deleted)' in filepath anchor", function()
    store.set("src/bar.lua", 10, 10, "", "deleted note", "old")
    local out = exporter.generate()
    assert.truthy(out:find("`src/bar.lua (deleted)`", 1, true))
  end)

  it("includes the code block when code is provided", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    assert.truthy(out:find("```text{7,9}", 1, true))
    assert.truthy(out:find("local x = 1", 1, true))
  end)

  it("includes all notes from all files", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    store.set("b.lua", 1, 1, "", "note b", "new")
    local out = exporter.generate()
    assert.truthy(out:find("`a.lua`", 1, true))
    assert.truthy(out:find("`b.lua`", 1, true))
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

  it("notes without text do not insert an empty paragraph", function()
    store.set("a.lua", 1, 1, "code", "", "new")
    local out = exporter.generate()
    assert.falsy(out:find("\n\n\n", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- "inline" format
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — inline format", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    setup_format("inline")
  end)

  it("includes filepath:line ref", function()
    store.set("src/foo.lua", 5, 5, "", "some note", "new")
    local out = exporter.generate()
    assert.truthy(out:find("src/foo.lua:5", 1, true))
  end)

  it("appends inline code when code is provided", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    -- first line of code appears inline, not as a block
    assert.truthy(out:find("`local x = 1`", 1, true))
    assert.falsy(out:find("```text", 1, true))
  end)

  it("marks old-side notes with '(deleted)' in ref", function()
    store.set("src/bar.lua", 10, 10, "", "deleted note", "old")
    local out = exporter.generate()
    assert.truthy(out:find("src/bar.lua (deleted):10", 1, true))
  end)

  it("note text appears on its own line(s) below the ref", function()
    store.set("a.lua", 1, 1, "", "line one\nline two", "new")
    local out = exporter.generate()
    assert.truthy(out:find("line one", 1, true))
    assert.truthy(out:find("line two", 1, true))
  end)

  it("includes all notes from all files", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    store.set("b.lua", 3, 3, "", "note b", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua:1", 1, true))
    assert.truthy(out:find("b.lua:3", 1, true))
    assert.truthy(out:find("note a", 1, true))
    assert.truthy(out:find("note b", 1, true))
  end)

  it("notes without text do not insert an empty paragraph", function()
    store.set("a.lua", 1, 1, "code", "", "new")
    local out = exporter.generate()
    assert.falsy(out:find("\n\n\n", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- "compact" format
-- ---------------------------------------------------------------------------

describe("review.exporter.generate() — compact format", function()
  before_each(function()
    state.reset()
    store.reset_cache()
    setup_format("compact")
  end)

  it("includes filepath:start-end range ref", function()
    store.set("src/foo.lua", 5, 8, "", "some note", "new")
    local out = exporter.generate()
    assert.truthy(out:find("src/foo.lua:5-8", 1, true))
  end)

  it("puts note text on the same line separated by ' - '", function()
    store.set("a.lua", 1, 3, "", "check this", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua:1-3 - check this", 1, true))
  end)

  it("collapses multiline note to a single line", function()
    store.set("a.lua", 1, 1, "", "line one\nline two", "new")
    local out = exporter.generate()
    assert.truthy(out:find("line one line two", 1, true))
    -- no literal newline between the two parts on the same entry line
    assert.falsy(out:match("line one\nline two"))
  end)

  it("marks old-side notes with '(deleted)' in ref", function()
    store.set("src/bar.lua", 10, 12, "", "deleted note", "old")
    local out = exporter.generate()
    assert.truthy(out:find("src/bar.lua (deleted):10-12", 1, true))
  end)

  it("does not include code blocks", function()
    store.set("a.lua", 7, 9, "local x = 1\nlocal y = 2", "check math", "new")
    local out = exporter.generate()
    assert.falsy(out:find("```", 1, true))
  end)

  it("includes all notes from all files", function()
    store.set("a.lua", 1, 1, "", "note a", "new")
    store.set("b.lua", 3, 5, "", "note b", "new")
    local out = exporter.generate()
    assert.truthy(out:find("a.lua:1-1", 1, true))
    assert.truthy(out:find("b.lua:3-5", 1, true))
    assert.truthy(out:find("note a",    1, true))
    assert.truthy(out:find("note b",    1, true))
  end)
end)
