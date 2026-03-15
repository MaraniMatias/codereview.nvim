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
  }
  return s.ui.diff
end

local function rebuild_visible_slice(diff)
  local total_lines = #diff.all_lines
  local visible_until = math.max(0, math.min(diff.visible_until or total_lines, total_lines))

  diff.visible_until = visible_until
  diff.is_truncated = visible_until < total_lines

  local lines = {}
  local line_types = {}
  local line_map = {}
  local new_to_display = {}
  local old_line_map = {}
  local old_to_display = {}
  local line_type_map = {}

  for display_lnum = 1, visible_until do
    lines[display_lnum] = diff.all_lines[display_lnum]
    line_types[display_lnum] = diff.all_line_types[display_lnum]

    local new_lnum = diff.all_line_map[display_lnum]
    if new_lnum then
      line_map[display_lnum] = new_lnum
      new_to_display[new_lnum] = display_lnum
    end

    local old_lnum = diff.all_old_line_map[display_lnum]
    if old_lnum then
      old_line_map[display_lnum] = old_lnum
      old_to_display[old_lnum] = display_lnum
    end

    local ltype = diff.all_line_type_map[display_lnum]
    if ltype then
      line_type_map[display_lnum] = ltype
    end
  end

  if diff.is_truncated then
    lines[visible_until + 1] = diff.truncation_line or "(diff truncated)"
    line_types[visible_until + 1] = "truncated"
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
