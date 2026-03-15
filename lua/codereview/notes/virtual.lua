local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")
local diff_state = require("codereview.ui.diff_view.state")

-- Namespace for extmarks
local ns_id = vim.api.nvim_create_namespace("codereview_notes")

local function set_buf_extmark(buf, lnum, opts)
  local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, lnum, 0, opts)
  if ok then
    return extmark_id
  end

  if opts.id ~= nil then
    local fallback_opts = vim.deepcopy(opts)
    fallback_opts.id = nil
    local fallback_ok, fallback_id = pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, lnum, 0, fallback_opts)
    if fallback_ok then
      return fallback_id
    end
  end

  return nil
end

local function clear_file_extmarks(buf, extmarks)
  for _, extmark_id in pairs(extmarks or {}) do
    M.del_extmark(buf, extmark_id)
  end
end

-- Set extmark for a note on a specific buffer line (0-indexed)
function M.set_extmark(buf, lnum, note, extmark_id)
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
    id = extmark_id,
  }

  return set_buf_extmark(buf, lnum, opts)
end

-- Remove extmark for a note
function M.del_extmark(buf, extmark_id)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_buf_del_extmark, buf, ns_id, extmark_id)
end

-- Clear all extmarks from a buffer
function M.clear_extmarks(buf)
  diff_state.clear_visible_extmarks(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

-- display: diff view state with visible new_to_display mapping
function M.render_notes(buf, filepath, display)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  display = display or {}
  local new_to_display = display.new_to_display or {}
  local buf_extmarks = diff_state.get_visible_extmarks(buf)
  local current_extmarks = buf_extmarks[filepath] or {}
  local next_extmarks = {}

  for rendered_filepath, extmarks in pairs(buf_extmarks) do
    if rendered_filepath ~= filepath then
      clear_file_extmarks(buf, extmarks)
    end
  end

  local notes = store.get_for_file(filepath)
  for _, note in ipairs(notes) do
    local display_lnum = new_to_display[note.line_start]
    if display_lnum then
      -- display_lnum is 1-based, extmark needs 0-based
      local extmark_id = M.set_extmark(buf, display_lnum - 1, note, current_extmarks[note.line_start])
      if extmark_id then
        next_extmarks[note.line_start] = extmark_id
      end
    end
  end

  for line_start, extmark_id in pairs(current_extmarks) do
    if next_extmarks[line_start] == nil then
      M.del_extmark(buf, extmark_id)
    end
  end

  diff_state.clear_visible_extmarks(buf)
  diff_state.set_visible_extmarks(buf, filepath, next_extmarks)
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
