local M = {}
local state = require("codereview.state")

-- NoteEntry structure:
-- {
--   filepath = "src/foo.js",
--   line_start = 42,
--   line_end = 42,
--   code = "const result = a + b;",
--   text = "revisar este cálculo",
--   extmark_id = nil,
-- }

-- Add or update a note
function M.set(filepath, line_start, line_end, code, text)
  local s = state.get()
  if not s.notes[filepath] then
    s.notes[filepath] = {}
  end
  local key = line_start
  s.notes[filepath][key] = {
    filepath = filepath,
    line_start = line_start,
    line_end = line_end or line_start,
    code = code or "",
    text = text,
    extmark_id = nil,
  }
  s.notes_dirty = true
  return s.notes[filepath][key]
end

-- Get a note by filepath and line
function M.get(filepath, line)
  local s = state.get()
  if not s.notes[filepath] then return nil end
  return s.notes[filepath][line]
end

-- Delete a note
function M.delete(filepath, line)
  local s = state.get()
  if s.notes[filepath] then
    s.notes[filepath][line] = nil
    s.notes_dirty = true
  end
end

-- Get all notes for a filepath, sorted by line number
function M.get_for_file(filepath)
  local s = state.get()
  if not s.notes[filepath] then return {} end
  local notes = {}
  for _, note in pairs(s.notes[filepath]) do
    table.insert(notes, note)
  end
  table.sort(notes, function(a, b) return a.line_start < b.line_start end)
  return notes
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
    return a.line_start < b.line_start
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

-- Serialize notes to JSON string for persistence
function M.serialize()
  local all = M.get_all()
  local result = {}
  for _, note in ipairs(all) do
    table.insert(result, {
      filepath = note.filepath,
      line_start = note.line_start,
      line_end = note.line_end,
      code = note.code,
      text = note.text,
    })
  end
  return vim.fn.json_encode(result)
end

-- Deserialize notes from JSON
function M.deserialize(json_str)
  local ok, data = pcall(vim.fn.json_decode, json_str)
  if not ok or type(data) ~= "table" then return end
  local s = state.get()
  s.notes = {}
  for _, entry in ipairs(data) do
    M.set(entry.filepath, entry.line_start, entry.line_end, entry.code, entry.text)
  end
end

return M
