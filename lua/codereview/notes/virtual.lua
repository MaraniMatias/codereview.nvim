local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace("codereview_notes")

-- Set extmark for a note on a specific buffer line (0-indexed)
function M.set_extmark(buf, lnum, note)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end

  local text = note.text or ""
  local tlen = config.options.virtual_text_truncate_len
  if #text > tlen then
    text = text:sub(1, tlen - 3) .. "..."
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

-- display: diff view state with visible new_to_display mapping
function M.render_notes(buf, filepath, display)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  M.clear_extmarks(buf)

  display = display or {}
  local new_to_display = display.new_to_display or {}
  local notes = store.get_for_file(filepath)
  for _, note in ipairs(notes) do
    local display_lnum = new_to_display[note.line_start]
    if display_lnum then
      -- display_lnum is 1-based, extmark needs 0-based
      M.set_extmark(buf, display_lnum - 1, note)
    end
  end
end

-- Toggle virtual text visibility
function M.toggle(buf, filepath, display)
  local s = state.get()
  if s.notes_visible then
    M.clear_extmarks(buf)
    s.notes_visible = false
  else
    M.render_notes(buf, filepath, display)
    s.notes_visible = true
  end
end

-- Get the namespace id
function M.get_ns()
  return ns_id
end

return M
