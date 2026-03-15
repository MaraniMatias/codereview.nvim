local M = {}

local actions = require("codereview.ui.explorer.actions")
local keymaps = require("codereview.ui.explorer.keymaps")
local view = require("codereview.ui.explorer.view")

function M.render()
  return view.render()
end

function M._apply_highlights(buf, lines)
  return view.apply_highlights(buf, lines)
end

function M.get_current_action()
  return view.get_current_action()
end

function M.select_file(idx)
  return actions.select_file(idx)
end

function M._move_cursor_to_file(idx)
  return view.move_cursor_to_file(idx)
end

function M.preview_action(action, opts)
  return actions.preview_action(action, opts)
end

function M.preview_current(opts)
  return actions.preview_current(opts)
end

function M.setup_keymaps(buf)
  return keymaps.setup(buf)
end

return M
