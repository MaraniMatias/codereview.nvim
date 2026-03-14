local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace("codereview_notes")

-- Set extmark for a note on a specific buffer line (0-indexed)
function M.set_extmark(buf, lnum, note)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end

  local text = note.text or ""
  if #text > 60 then
    text = text:sub(1, 57) .. "..."
  end
  -- Remove newlines from virtual text display
  text = text:gsub("\n", " ")
  local virt_text = { { "  📝 " .. text, "Comment" } }

  local opts = {
    virt_text = virt_text,
    virt_text_pos = "eol",
    hl_mode = "combine",
  }

  local extmark_id = vim.api.nvim_buf_set_extmark(buf, ns_id, lnum, 0, opts)
  note.extmark_id = extmark_id
  return extmark_id
end

-- Remove extmark for a note
function M.del_extmark(buf, extmark_id)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_id, extmark_id)
end

-- Clear all extmarks from a buffer
function M.clear_extmarks(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

-- Render all notes for the current file into the diff buffer
-- buf: diff buffer id, filepath: current file path
-- line_map: table mapping display line index (1-based) -> new_lnum (1-based)
function M.render_notes(buf, filepath, line_map)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  M.clear_extmarks(buf)

  local notes = store.get_for_file(filepath)
  for _, note in ipairs(notes) do
    for display_lnum, new_lnum in pairs(line_map) do
      if new_lnum == note.line_start then
        -- display_lnum is 1-based, extmark needs 0-based
        M.set_extmark(buf, display_lnum - 1, note)
        break
      end
    end
  end
end

-- Toggle virtual text visibility
function M.toggle(buf, filepath, line_map)
  local s = state.get()
  if s.notes_visible then
    M.clear_extmarks(buf)
    s.notes_visible = false
  else
    M.render_notes(buf, filepath, line_map)
    s.notes_visible = true
  end
end

-- Get the namespace id
function M.get_ns()
  return ns_id
end

return M
