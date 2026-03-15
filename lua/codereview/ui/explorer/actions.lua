local M = {}

local state = require("codereview.state")
local diff_view = require("codereview.ui.diff_view")
local layout = require("codereview.ui.layout")
local explorer_state = require("codereview.ui.explorer.state")
local view = require("codereview.ui.explorer.view")

local function action_key(action)
  if not action then
    return nil
  end
  if action.type == "file" then
    return "file:" .. action.idx
  end
  if action.type == "note" then
    return "note:" .. action.filepath .. ":" .. action.line
  end
  return nil
end

local function find_file_idx(filepath)
  local s = state.get()
  for idx, file in ipairs(s.files) do
    if file.path == filepath then
      return idx
    end
  end
  return nil
end

function M.clear_last_preview_key()
  explorer_state.set_last_preview_key(nil)
end

function M.select_file(idx)
  local s = state.get()
  local opts = {}

  if type(idx) == "table" then
    opts = idx
    idx = opts.idx
  end

  if not idx or idx < 1 or idx > #s.files then
    return
  end
  if opts.move_cursor == nil then
    opts.move_cursor = true
  end

  local win = s.windows.explorer
  local cursor = nil
  if opts.preserve_cursor and win and vim.api.nvim_win_is_valid(win) then
    cursor = vim.api.nvim_win_get_cursor(win)
  end

  local changed = s.current_file_idx ~= idx
  s.current_file_idx = idx

  if changed or opts.force_render then
    view.render()
  end

  if opts.move_cursor then
    view.move_cursor_to_file(idx)
  else
    view.restore_cursor(cursor)
  end
end

function M.preview_action(action, opts)
  opts = opts or {}
  if not action then
    return
  end

  if action.type == "file" then
    M.select_file({
      idx = action.idx,
      preserve_cursor = opts.preserve_cursor,
      move_cursor = opts.move_cursor,
    })
    diff_view.show_file(action.idx)
  elseif action.type == "note" then
    local file_idx = find_file_idx(action.filepath)
    if not file_idx then
      return
    end
    M.select_file({
      idx = file_idx,
      preserve_cursor = opts.preserve_cursor,
      move_cursor = opts.move_cursor,
    })
    diff_view.show_file(file_idx)
    diff_view.jump_to_line(action.line)
  else
    return
  end

  explorer_state.set_last_preview_key(action_key(action))

  if opts.focus_diff then
    layout.focus_diff()
  end
end

function M.preview_current(opts)
  local action = view.get_current_action()
  local key = action_key(action)

  if not key then
    explorer_state.set_last_preview_key(nil)
    return
  end
  if key == explorer_state.get().last_preview_key then
    return
  end

  M.preview_action(action, opts)
end

function M.open_current()
  local action = view.get_current_action()
  if not action then
    return
  end
  M.preview_action(action, { focus_diff = true, move_cursor = true })
end

function M.toggle_notes()
  local action = view.get_current_action()
  if not action or action.type ~= "file" then
    return
  end

  local s = state.get()
  local file = s.files[action.idx]
  if not file then
    return
  end

  file.expanded = not file.expanded
  view.render()
  M.clear_last_preview_key()
  M.preview_current({ preserve_cursor = true })
end

function M.next_file()
  local s = state.get()
  if s.current_file_idx < #s.files then
    M.preview_action({ type = "file", idx = s.current_file_idx + 1 }, { move_cursor = true })
  end
end

function M.prev_file()
  local s = state.get()
  if s.current_file_idx > 1 then
    M.preview_action({ type = "file", idx = s.current_file_idx - 1 }, { move_cursor = true })
  end
end

function M.refresh()
  require("codereview").refresh()
end

function M.quit()
  layout.safe_close(false)
end

function M.cycle_focus()
  layout.focus_diff()
end

function M.save()
  require("codereview.review.exporter").save_with_prompt()
end

return M
