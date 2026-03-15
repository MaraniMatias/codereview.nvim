local M = {}
local state = require("codereview.state")
local _sorted_cache = {}   -- filepath -> sorted notes array

-- NoteEntry structure:
-- {
--   filepath = "src/foo.js",
--   line_start = 42,
--   line_end = 42,
--   code = "const result = a + b;",
--   text = "revisar este cálculo",
--   side = "new" | "old",
-- }

local function make_key(line_start, side)
  if side == "old" then
    return "old:" .. line_start
  end
  return line_start
end

-- Add or update a note
function M.set(filepath, line_start, line_end, code, text, side)
  local s = state.get()
  if not s.notes[filepath] then
    s.notes[filepath] = {}
  end
  side = side or "new"
  local key = make_key(line_start, side)
  s.notes[filepath][key] = {
    filepath = filepath,
    line_start = line_start,
    line_end = line_end or line_start,
    code = code or "",
    text = text,
    side = side,
  }
  s.notes_dirty = true
  _sorted_cache[filepath] = nil
  return s.notes[filepath][key]
end

-- Get a note by filepath and line
function M.get(filepath, line, side)
  local s = state.get()
  if not s.notes[filepath] then return nil end
  local key = make_key(line, side or "new")
  return s.notes[filepath][key]
end

-- Delete a note
function M.delete(filepath, line, side)
  local s = state.get()
  if s.notes[filepath] then
    local key = make_key(line, side or "new")
    s.notes[filepath][key] = nil
    s.notes_dirty = true
    _sorted_cache[filepath] = nil
  end
end

-- Get all notes for a filepath, sorted by line number
function M.get_for_file(filepath)
  if _sorted_cache[filepath] then return _sorted_cache[filepath] end
  local s = state.get()
  if not s.notes[filepath] then return {} end
  local notes = {}
  for _, note in pairs(s.notes[filepath]) do
    table.insert(notes, note)
  end
  table.sort(notes, function(a, b)
    if a.line_start ~= b.line_start then
      return a.line_start < b.line_start
    end
    return (a.side or "new") < (b.side or "new")
  end)
  _sorted_cache[filepath] = notes
  return notes
end

function M.reset_cache()
  _sorted_cache = {}
end

-- Get all notes across all files, sorted by filepath then line
function M.get_all()
  local s = state.get()
  local all = {}
  for filepath, file_notes in pairs(s.notes) do
    for _, note in pairs(file_notes) do
      table.insert(all, note)
    end
  end
  table.sort(all, function(a, b)
    if a.filepath ~= b.filepath then
      return a.filepath < b.filepath
    end
    if a.line_start ~= b.line_start then
      return a.line_start < b.line_start
    end
    return (a.side or "new") < (b.side or "new")
  end)
  return all
end

-- Count notes for a filepath
function M.count_for_file(filepath)
  local s = state.get()
  if not s.notes[filepath] then return 0 end
  local count = 0
  for _ in pairs(s.notes[filepath]) do
    count = count + 1
  end
  return count
end

-- Check if any notes exist
function M.has_any()
  local s = state.get()
  for _, file_notes in pairs(s.notes) do
    for _ in pairs(file_notes) do
      return true
    end
  end
  return false
end

return M
