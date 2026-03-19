local M = {}

local state = require("codereview.state")

local function ensure_explorer_state()
  local s = state.get()
  s.ui = s.ui or {}
  s.ui.explorer = s.ui.explorer or {
    actions_by_line = {},
    dim_by_line = {},  -- lnum → { col_start, col_end } where dimmed dir portion lives (flat layout)
    tag_ranges = {},   -- lnum → { { col_start, col_end }, ... } for note_marker/binary_tag highlights
    last_preview_key = nil,
  }
  return s.ui.explorer
end

function M.get()
  return ensure_explorer_state()
end

function M.set_actions_by_line(actions_by_line)
  ensure_explorer_state().actions_by_line = actions_by_line or {}
end

function M.set_dim_by_line(dim_by_line)
  ensure_explorer_state().dim_by_line = dim_by_line or {}
end

function M.set_tag_ranges(tag_ranges)
  ensure_explorer_state().tag_ranges = tag_ranges or {}
end

function M.set_last_preview_key(key)
  ensure_explorer_state().last_preview_key = key
end

return M
