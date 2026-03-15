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

  for display_lnum = 1, visible_until do
    lines[display_lnum] = diff.all_lines[display_lnum]
    line_types[display_lnum] = diff.all_line_types[display_lnum]

    local new_lnum = diff.all_line_map[display_lnum]
    if new_lnum then
      line_map[display_lnum] = new_lnum
      new_to_display[new_lnum] = display_lnum
    end
  end

  if diff.is_truncated then
    lines[visible_until + 1] = diff.truncation_line or "(diff truncado)"
    line_types[visible_until + 1] = "truncated"
  end

  diff.lines = lines
  diff.line_types = line_types
  diff.line_map = line_map
  diff.new_to_display = new_to_display
end

function M.get()
  return ensure_diff_state()
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
  diff.visible_until = 0
  diff.is_truncated = false
  diff.truncation_line = nil
  diff.pending_jump_lnum = nil
end

function M.set(display)
  local diff = ensure_diff_state()
  diff.all_lines = display.all_lines or {}
  diff.all_line_types = display.all_line_types or {}
  diff.all_line_map = display.all_line_map or {}
  diff.all_new_to_display = display.all_new_to_display or {}
  diff.visible_until = display.visible_until or #diff.all_lines
  if display.truncation_line ~= nil then
    diff.truncation_line = display.truncation_line
  end
  if display.pending_jump_lnum ~= nil then
    diff.pending_jump_lnum = display.pending_jump_lnum
  end
  rebuild_visible_slice(diff)
end

function M.set_visible_until(visible_until)
  local diff = ensure_diff_state()
  diff.visible_until = visible_until
  rebuild_visible_slice(diff)
end

function M.set_pending_jump(new_lnum)
  local diff = ensure_diff_state()
  diff.pending_jump_lnum = new_lnum
end

return M
