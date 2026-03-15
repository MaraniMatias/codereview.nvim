local M = {}

local state = require("codereview.state")

local function ensure_diff_state()
  local s = state.get()
  s.ui = s.ui or {}
  s.ui.diff = s.ui.diff or {
    lines = {},
    line_types = {},
    line_map = {},
  }
  return s.ui.diff
end

function M.get()
  return ensure_diff_state()
end

function M.reset()
  local diff = ensure_diff_state()
  diff.lines = {}
  diff.line_types = {}
  diff.line_map = {}
end

function M.set(display)
  local diff = ensure_diff_state()
  diff.lines = display.lines or {}
  diff.line_types = display.line_types or {}
  diff.line_map = display.line_map or {}
end

return M
