local M = {}

local state = require("codereview.state")

local function ensure_diff_state()
  local s = state.get()
  s.ui = s.ui or {}
  s.ui.diff = s.ui.diff or {
    lines = {},
    line_types = {},
    line_map = {},
    new_to_display = {},
    all_lines = {},
    all_line_types = {},
    all_line_map = {},
    all_new_to_display = {},
    all_old_line_map = {},
    all_old_to_display = {},
    all_line_type_map = {},
    old_line_map = {},
    old_to_display = {},
    line_type_map = {},
    visible_extmarks = {}, -- visible_extmarks[buf][filepath][key] = extmark_id
    visible_until = 0,
    is_truncated = false,
    truncation_line = nil,
    pending_jump_lnum = nil,
    folded_hunks = {}, -- set of all_lines indices (hdr lines) that are folded
  }
  return s.ui.diff
end

-- Find the end of a hunk: the line before the next "hdr" or end of data
local function find_hunk_end(all_line_types, hdr_idx, total)
  for i = hdr_idx + 1, total do
    if all_line_types[i] == "hdr" then
      return i - 1
    end
  end
  return total
end

-- Count content lines in a hunk (excluding the header itself)
local function count_hunk_lines(hdr_idx, hunk_end)
  return hunk_end - hdr_idx
end

local function rebuild_visible_slice(diff)
  local total_lines = #diff.all_lines
  local visible_until = math.max(0, math.min(diff.visible_until or total_lines, total_lines))

  diff.visible_until = visible_until
  diff.is_truncated = visible_until < total_lines

  local folded = diff.folded_hunks or {}
  local has_folds = next(folded) ~= nil

  local lines = {}
  local line_types = {}
  local line_map = {}
  local new_to_display = {}
  local old_line_map = {}
  local old_to_display = {}
  local line_type_map = {}

  local out_idx = 0
  local src_idx = 1

  while src_idx <= visible_until do
    local ltype = diff.all_line_types[src_idx]

    -- Check if this is a folded hunk header
    if has_folds and ltype == "hdr" and folded[src_idx] then
      local hunk_end = find_hunk_end(diff.all_line_types, src_idx, total_lines)
      local visible_hunk_end = math.min(hunk_end, visible_until)
      local hidden_count = count_hunk_lines(src_idx, visible_hunk_end)

      out_idx = out_idx + 1
      local header_text = diff.all_lines[src_idx]
      lines[out_idx] = "▸ " .. header_text .. " (" .. hidden_count .. " lines)"
      line_types[out_idx] = "hdr"
      -- Skip all lines in this hunk
      src_idx = visible_hunk_end + 1
    else
      out_idx = out_idx + 1
      lines[out_idx] = diff.all_lines[src_idx]
      line_types[out_idx] = ltype

      local new_lnum = diff.all_line_map[src_idx]
      if new_lnum then
        line_map[out_idx] = new_lnum
        new_to_display[new_lnum] = out_idx
      end

      local old_lnum = diff.all_old_line_map[src_idx]
      if old_lnum then
        old_line_map[out_idx] = old_lnum
        old_to_display[old_lnum] = out_idx
      end

      local lt = diff.all_line_type_map[src_idx]
      if lt then
        line_type_map[out_idx] = lt
      end

      src_idx = src_idx + 1
    end
  end

  if diff.is_truncated then
    out_idx = out_idx + 1
    lines[out_idx] = diff.truncation_line or "(diff truncated)"
    line_types[out_idx] = "truncated"
  end

  diff.lines = lines
  diff.line_types = line_types
  diff.line_map = line_map
  diff.new_to_display = new_to_display
  diff.old_line_map = old_line_map
  diff.old_to_display = old_to_display
  diff.line_type_map = line_type_map
end

local function ensure_diff_old_state()
  local s = state.get()
  s.ui = s.ui or {}
  s.ui.diff_old = s.ui.diff_old or {
    lines = {},
    line_types = {},
    line_map = {},
    new_to_display = {},
    all_lines = {},
    all_line_types = {},
    all_line_map = {},
    all_new_to_display = {},
    all_old_line_map = {},
    all_old_to_display = {},
    all_line_type_map = {},
    old_line_map = {},
    old_to_display = {},
    line_type_map = {},
    visible_extmarks = {},
    visible_until = 0,
    is_truncated = false,
    truncation_line = nil,
    pending_jump_lnum = nil,
    folded_hunks = {},
  }
  return s.ui.diff_old
end

function M.get()
  return ensure_diff_state()
end

function M.get_old()
  return ensure_diff_old_state()
end

function M.reset()
  local diff = ensure_diff_state()
  diff.lines = {}
  diff.line_types = {}
  diff.line_map = {}
  diff.new_to_display = {}
  diff.all_lines = {}
  diff.all_line_types = {}
  diff.all_line_map = {}
  diff.all_new_to_display = {}
  diff.all_old_line_map = {}
  diff.all_old_to_display = {}
  diff.all_line_type_map = {}
  diff.old_line_map = {}
  diff.old_to_display = {}
  diff.line_type_map = {}
  diff.visible_extmarks = {}
  diff.visible_until = 0
  diff.is_truncated = false
  diff.truncation_line = nil
  diff.pending_jump_lnum = nil
  diff.folded_hunks = {}
end

function M.reset_old()
  local diff = ensure_diff_old_state()
  diff.lines = {}
  diff.line_types = {}
  diff.line_map = {}
  diff.new_to_display = {}
  diff.all_lines = {}
  diff.all_line_types = {}
  diff.all_line_map = {}
  diff.all_new_to_display = {}
  diff.all_old_line_map = {}
  diff.all_old_to_display = {}
  diff.all_line_type_map = {}
  diff.old_line_map = {}
  diff.old_to_display = {}
  diff.line_type_map = {}
  diff.visible_extmarks = {}
  diff.visible_until = 0
  diff.is_truncated = false
  diff.truncation_line = nil
  diff.pending_jump_lnum = nil
  diff.folded_hunks = {}
end

function M.set_old(display)
  local diff = ensure_diff_old_state()
  diff.all_lines = display.all_lines or {}
  diff.all_line_types = display.all_line_types or {}
  diff.all_line_map = display.all_line_map or {}
  diff.all_new_to_display = display.all_lnum_to_display or {}
  diff.all_old_line_map = display.all_line_map or {}
  diff.all_old_to_display = display.all_lnum_to_display or {}
  diff.all_line_type_map = display.all_line_type_map or {}
  diff.visible_until = display.visible_until or #diff.all_lines
  if display.truncation_line ~= nil then
    diff.truncation_line = display.truncation_line
  end
  rebuild_visible_slice(diff)
end

function M.set(display)
  local diff = ensure_diff_state()
  diff.all_lines = display.all_lines or {}
  diff.all_line_types = display.all_line_types or {}
  diff.all_line_map = display.all_line_map or {}
  diff.all_new_to_display = display.all_new_to_display or {}
  diff.all_old_line_map = display.all_old_line_map or {}
  diff.all_old_to_display = display.all_old_to_display or {}
  diff.all_line_type_map = display.all_line_type_map or {}
  diff.visible_until = display.visible_until or #diff.all_lines
  if display.truncation_line ~= nil then
    diff.truncation_line = display.truncation_line
  end
  if display.pending_jump_lnum ~= nil then
    diff.pending_jump_lnum = display.pending_jump_lnum
  end
  rebuild_visible_slice(diff)
end

-- Set new-side display for split mode (uses all_lnum_to_display from split builder)
function M.set_new(display)
  local diff = ensure_diff_state()
  diff.all_lines = display.all_lines or {}
  diff.all_line_types = display.all_line_types or {}
  diff.all_line_map = display.all_line_map or {}
  diff.all_new_to_display = display.all_lnum_to_display or {}
  diff.all_old_line_map = {}
  diff.all_old_to_display = {}
  diff.all_line_type_map = display.all_line_type_map or {}
  diff.visible_until = display.visible_until or #diff.all_lines
  if display.truncation_line ~= nil then
    diff.truncation_line = display.truncation_line
  end
  rebuild_visible_slice(diff)
end

function M.set_visible_until(visible_until)
  local diff = ensure_diff_state()
  diff.visible_until = visible_until
  rebuild_visible_slice(diff)
end

function M.set_visible_until_both(visible_until)
  local diff = ensure_diff_state()
  diff.visible_until = visible_until
  rebuild_visible_slice(diff)
  local diff_old = ensure_diff_old_state()
  diff_old.visible_until = visible_until
  rebuild_visible_slice(diff_old)
end

function M.set_pending_jump(new_lnum)
  local diff = ensure_diff_state()
  diff.pending_jump_lnum = new_lnum
end

function M.get_visible_extmarks(buf)
  local diff = ensure_diff_state()
  if buf == nil then
    return diff.visible_extmarks
  end

  diff.visible_extmarks[buf] = diff.visible_extmarks[buf] or {}
  return diff.visible_extmarks[buf]
end

function M.set_visible_extmarks(buf, filepath, extmarks)
  if buf == nil or filepath == nil then
    return
  end

  local buf_extmarks = M.get_visible_extmarks(buf)
  if extmarks and next(extmarks) ~= nil then
    buf_extmarks[filepath] = extmarks
  else
    buf_extmarks[filepath] = nil
  end
end

function M.get_old_visible_extmarks(buf)
  local diff = ensure_diff_old_state()
  if buf == nil then
    return diff.visible_extmarks
  end
  diff.visible_extmarks[buf] = diff.visible_extmarks[buf] or {}
  return diff.visible_extmarks[buf]
end

function M.set_old_visible_extmarks(buf, filepath, extmarks)
  if buf == nil or filepath == nil then return end
  local buf_extmarks = M.get_old_visible_extmarks(buf)
  if extmarks and next(extmarks) ~= nil then
    buf_extmarks[filepath] = extmarks
  else
    buf_extmarks[filepath] = nil
  end
end

function M.clear_old_visible_extmarks(buf, filepath)
  local diff = ensure_diff_old_state()
  if buf == nil then
    diff.visible_extmarks = {}
    return
  end
  if filepath == nil then
    diff.visible_extmarks[buf] = nil
    return
  end
  local buf_extmarks = diff.visible_extmarks[buf]
  if not buf_extmarks then return end
  buf_extmarks[filepath] = nil
  if next(buf_extmarks) == nil then
    diff.visible_extmarks[buf] = nil
  end
end

-- Find the hunk header (all_lines index) that contains the given display line.
-- Returns the all_lines index of the hdr line, or nil.
function M.find_hunk_header_for_line(display_lnum)
  local diff = ensure_diff_state()
  -- Walk backwards from display_lnum to find the nearest "hdr" line
  for i = display_lnum, 1, -1 do
    if diff.all_line_types[i] == "hdr" then
      return i
    end
  end
  return nil
end

-- Toggle fold state for a hunk identified by its header line index in all_lines
function M.toggle_hunk_fold(hdr_idx)
  local diff = ensure_diff_state()
  if diff.folded_hunks[hdr_idx] then
    diff.folded_hunks[hdr_idx] = nil
  else
    diff.folded_hunks[hdr_idx] = true
  end
  rebuild_visible_slice(diff)
end

-- Toggle fold on both sides (split mode)
function M.toggle_hunk_fold_both(hdr_idx)
  local diff = ensure_diff_state()
  local diff_old = ensure_diff_old_state()
  local new_state = not diff.folded_hunks[hdr_idx]
  if new_state then
    diff.folded_hunks[hdr_idx] = true
    diff_old.folded_hunks[hdr_idx] = true
  else
    diff.folded_hunks[hdr_idx] = nil
    diff_old.folded_hunks[hdr_idx] = nil
  end
  rebuild_visible_slice(diff)
  rebuild_visible_slice(diff_old)
end

function M.is_hunk_folded(hdr_idx)
  local diff = ensure_diff_state()
  return diff.folded_hunks[hdr_idx] == true
end

function M.clear_visible_extmarks(buf, filepath)
  local diff = ensure_diff_state()

  if buf == nil then
    diff.visible_extmarks = {}
    return
  end

  if filepath == nil then
    diff.visible_extmarks[buf] = nil
    return
  end

  local buf_extmarks = diff.visible_extmarks[buf]
  if not buf_extmarks then
    return
  end

  buf_extmarks[filepath] = nil
  if next(buf_extmarks) == nil then
    diff.visible_extmarks[buf] = nil
  end
end

return M
