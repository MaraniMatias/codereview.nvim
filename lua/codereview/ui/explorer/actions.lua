local M = {}

local state = require("codereview.state")
local diff_view = require("codereview.ui.diff_view")
local diff_state = require("codereview.ui.diff_view.state")
local layout = require("codereview.ui.layout")
local note_float = require("codereview.ui.note_float")
local store = require("codereview.notes.store")
local explorer_state = require("codereview.ui.explorer.state")
local view = require("codereview.ui.explorer.view")
local valid = require("codereview.util.validate")
local prompt = require("codereview.util.prompt")

local function action_key(action)
  if not action then
    return nil
  end
  if action.type == "file" then
    return "file:" .. action.idx
  end
  if action.type == "note" then
    return "note:" .. action.filepath .. ":" .. action.line .. ":" .. (action.side or "new")
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
    opts.move_cursor = not opts.preserve_cursor
  end

  local win = s.windows.explorer
  local cursor = nil
  if opts.preserve_cursor and valid.win(win) then
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

  local s = state.get()
  local prev_file_idx = s.current_file_idx

  if action.type == "file" then
    M.select_file({
      idx = action.idx,
      preserve_cursor = opts.preserve_cursor,
      move_cursor = opts.move_cursor,
    })
    if action.idx ~= prev_file_idx or #diff_state.get().all_lines == 0 then
      diff_view.show_file(action.idx)
    end
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
    if file_idx ~= prev_file_idx or #diff_state.get().all_lines == 0 then
      diff_view.show_file(file_idx)
    end
    diff_view.jump_to_line_sided(action.line, action.side or "new")
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

function M.edit_current_note()
  local action = view.get_current_action()
  if not action or action.type ~= "note" then return end
  local note = store.get(action.filepath, action.line, action.side)
  if not note then return end
  note_float.open(action.filepath, action.line, action.line, note.code, note.text, action.side)
end

function M.toggle_notes()
  local action = view.get_current_action()
  if not action then
    return
  end

  local s = state.get()
  local file_idx
  if action.type == "file" then
    file_idx = action.idx
  elseif action.type == "note" then
    file_idx = find_file_idx(action.filepath)
  end

  if not file_idx then
    return
  end

  local file = s.files[file_idx]
  if not file then
    return
  end

  file.expanded = not file.expanded
  view.render()
  M.clear_last_preview_key()
  M.preview_current({ preserve_cursor = true })
end

local function get_cursor_file_idx()
  local action = view.get_current_action()
  if not action then
    return state.get().current_file_idx
  end
  if action.type == "file" then
    return action.idx
  elseif action.type == "note" then
    return find_file_idx(action.filepath) or state.get().current_file_idx
  end
  return state.get().current_file_idx
end

function M.next_file()
  local s = state.get()
  local from = get_cursor_file_idx()
  if from < #s.files then
    M.preview_action({ type = "file", idx = from + 1 }, { move_cursor = true })
  else
    vim.api.nvim_echo({ { "CodeReview: no more files", "Comment" } }, false, {})
  end
end

function M.prev_file()
  local from = get_cursor_file_idx()
  if from > 1 then
    M.preview_action({ type = "file", idx = from - 1 }, { move_cursor = true })
  else
    vim.api.nvim_echo({ { "CodeReview: already at first file", "Comment" } }, false, {})
  end
end

function M.refresh()
  require("codereview").refresh()
end

function M.toggle_layout()
  local cfg = require("codereview.config").options
  cfg.explorer_layout = (cfg.explorer_layout == "tree") and "flat" or "tree"
  view.render()
  vim.api.nvim_echo({ { "CodeReview: layout → " .. cfg.explorer_layout, "Comment" } }, false, {})
end

function M.quit()
  if note_float.is_open() then
    note_float.ask_save_or_discard()
    return
  end
  layout.safe_close(false)
end

function M.cycle_focus()
  layout.focus_diff()
end

function M.save()
  require("codereview.review.exporter").save_with_prompt()
end

function M.delete_note(force)
  local action = view.get_current_action()
  if not action or action.type ~= "note" then
    return
  end

  local function do_delete()
    store.delete(action.filepath, action.line, action.side or "new")
    view.render()
    diff_view.refresh_notes()
    M.clear_last_preview_key()
    M.preview_current({ preserve_cursor = true })
  end

  if force then
    do_delete()
  else
    if prompt.confirm("Delete note?") then
      do_delete()
    end
  end
end

function M.show_help()
  local km = require("codereview.config").options.keymaps
  local lines = {
    " CodeReview — Keymaps",
    " ──────────────────────────────",
    " Explorer",
    " <CR> / l      Open file in diff",
    " " .. (km.toggle_notes or "za") .. "             Toggle notes",
    " d             Delete note (confirm)",
    " D             Delete note (force)",
    " " .. (km.next_file or "]f") .. " / " .. (km.prev_file or "[f") .. "         Next / prev file",
    " " .. (km.refresh or "R") .. "             Refresh",
    " " .. (km.quit or "q") .. "             Quit",
    " " .. (km.cycle_focus or "<Tab>") .. "          Cycle focus",
    " " .. (km.toggle_layout or "t") .. "             Toggle flat / tree",
    " ?             This help",
    " ──────────────────────────────",
    " Diff view",
    " " .. (km.note or "n") .. "             Add note",
    " " .. (km.next_note or "]n") .. " / " .. (km.prev_note or "[n") .. "         Next / prev note",
    " " .. (km.next_file or "]f") .. " / " .. (km.prev_file or "[f") .. "         Next / prev file",
    " " .. (km.load_more_diff or "L") .. "             Load more diff",
    " " .. (km.notes_picker or "<Space>n") .. "       Notes picker",
    " " .. (km.toggle_virtual_text or "<leader>uh") .. "    Toggle virtual text",
    " " .. (km.toggle_hunk_fold or "za") .. "            Toggle hunk fold",
    " " .. (km.go_to_file or "gf") .. "            Go to file (new tab)",
    " " .. (km.view_file or "gF") .. "            View full file (new tab)",
    " ──────────────────────────────",
    " Note editor",
    " <C-s> / :w    Save note",
    " <C-d>         Delete note",
    " q             Discard",
    " <Esc>         Save note",
    " ──────────────────────────────",
    " Press any key to close",
  }
  if km.save then
    table.insert(lines, 10, " " .. km.save .. "             Save review")
  end

  local width = 36
  local height = #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local ui = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  local ns = vim.api.nvim_create_namespace("codereview_help")
  for lnum, line in ipairs(lines) do
    local row0 = lnum - 1
    if lnum == 1 then
      vim.api.nvim_buf_add_highlight(buf, ns, "Title", row0, 0, -1)
    elseif line:match("^%s*─") then
      vim.api.nvim_buf_add_highlight(buf, ns, "Comment", row0, 0, -1)
    elseif line == " Explorer" or line == " Diff view" or line == " Note editor" then
      vim.api.nvim_buf_add_highlight(buf, ns, "Special", row0, 0, -1)
    elseif lnum == #lines then
      vim.api.nvim_buf_add_highlight(buf, ns, "Comment", row0, 0, -1)
    end
  end

  local close = function() vim.api.nvim_win_close(win, true) end
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "?", close, { buffer = buf, nowait = true, silent = true })
end

return M
