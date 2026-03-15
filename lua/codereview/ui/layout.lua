local M = {}
local config = require("codereview.config")
local state = require("codereview.state")

local lifecycle_group = vim.api.nvim_create_augroup("CodeReviewLayoutLifecycle", { clear = false })
local buffer_handlers_group = vim.api.nvim_create_augroup("CodeReviewBufferHandlers", { clear = false })
local active_session_id = 0
local blocked_close_session_id = nil
local teardown_in_progress = false
local teardown_scheduled = false
local setup_lifecycle_autocmds

local function is_valid_window(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buffer(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function window_belongs_to_tab(win, tab)
  return vim.api.nvim_win_get_tabpage(win) == tab
end

local function has_layout_state(s)
  return s.tab ~= nil
    or s.windows.explorer ~= nil
    or s.windows.diff ~= nil
    or s.buffers.explorer ~= nil
    or s.buffers.diff ~= nil
end

local function clear_lifecycle_autocmds()
  pcall(vim.api.nvim_clear_autocmds, { group = lifecycle_group })
end

local function clear_buffer_handler_autocmds(buf, event)
  pcall(vim.api.nvim_clear_autocmds, {
    group = buffer_handlers_group,
    buffer = buf,
    event = event,
  })
end

local function set_buffer_options(buf, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { buf = buf })
  end
end

local function set_window_options(win, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { win = win })
  end
end

local function create_explorer_buffer()
  local explorer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(explorer_buf, "codereview://explorer")
  set_buffer_options(explorer_buf, {
    buftype = "acwrite",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
    filetype = "codereview-explorer",
  })
  return explorer_buf
end

local function create_diff_buffer()
  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(diff_buf, "codereview://diff")
  set_buffer_options(diff_buf, {
    buftype = "acwrite",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
  })
  return diff_buf
end

local function configure_panel_window(win)
  set_window_options(win, {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    wrap = false,
    cursorline = true,
  })
end

local function restore_previous_window(prev_win)
  if is_valid_window(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

local function call_in_tab(tab, callback)
  if not is_valid_tab(tab) then
    return false
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local ok, result = pcall(function()
    if current_tab ~= tab then
      vim.api.nvim_set_current_tabpage(tab)
    end

    return callback()
  end)

  if current_tab ~= tab and is_valid_tab(current_tab) then
    pcall(vim.api.nvim_set_current_tabpage, current_tab)
  end

  return ok, result
end

local function dismantle_review_tab(review_tab, buffers)
  if not is_valid_tab(review_tab) then
    return true
  end

  local ok = call_in_tab(review_tab, function()
    local wins = vim.api.nvim_tabpage_list_wins(review_tab)

    for idx = #wins, 2, -1 do
      local win = wins[idx]
      if is_valid_window(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    vim.cmd("enew")
  end)

  if not ok then
    return false
  end

  for _, buf in ipairs(buffers) do
    if is_valid_buffer(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  return true
end

local function finalize_close(prev_win)
  clear_lifecycle_autocmds()
  state.reset()
  blocked_close_session_id = nil
  teardown_in_progress = false
  teardown_scheduled = false
  restore_previous_window(prev_win)
end

local function restore_blocked_layout()
  local s = state.get()
  if not is_valid_tab(s.tab) then
    return false
  end

  local explorer_missing = not is_valid_window(s.windows.explorer) or not is_valid_buffer(s.buffers.explorer)
  local diff_missing = not is_valid_window(s.windows.diff) or not is_valid_buffer(s.buffers.diff)

  if not explorer_missing and not diff_missing then
    return M.is_open()
  end

  if explorer_missing and diff_missing then
    return false
  end

  local cfg = config.options
  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")

  local ok = call_in_tab(s.tab, function()
    local current_win = vim.api.nvim_get_current_win()

    if explorer_missing then
      local diff_win = s.windows.diff
      if not is_valid_window(diff_win) then
        error("missing diff window")
      end

      vim.api.nvim_set_current_win(diff_win)
      vim.cmd("leftabove vsplit")

      local explorer_win = vim.api.nvim_get_current_win()
      local explorer_buf = create_explorer_buffer()

      vim.api.nvim_win_set_buf(explorer_win, explorer_buf)
      vim.api.nvim_set_option_value("winfixwidth", true, { win = explorer_win })
      vim.api.nvim_set_option_value("winfixwidth", false, { win = diff_win })
      vim.api.nvim_win_set_width(explorer_win, cfg.explorer_width)

      configure_panel_window(explorer_win)
      configure_panel_window(diff_win)

      s.windows.explorer = explorer_win
      s.buffers.explorer = explorer_buf

      explorer.setup_keymaps(explorer_buf)
      explorer.render()
    end

    if diff_missing then
      local explorer_win = s.windows.explorer
      if not is_valid_window(explorer_win) then
        error("missing explorer window")
      end

      vim.api.nvim_set_current_win(explorer_win)
      vim.cmd("rightbelow vsplit")

      local diff_win = vim.api.nvim_get_current_win()
      local diff_buf = create_diff_buffer()

      vim.api.nvim_win_set_buf(diff_win, diff_buf)
      vim.api.nvim_set_option_value("winfixwidth", true, { win = explorer_win })
      vim.api.nvim_set_option_value("winfixwidth", false, { win = diff_win })
      vim.api.nvim_win_set_width(explorer_win, cfg.explorer_width)

      configure_panel_window(explorer_win)
      configure_panel_window(diff_win)

      s.windows.diff = diff_win
      s.buffers.diff = diff_buf

      diff_view.setup_keymaps(diff_buf)
      if #s.files > 0 then
        diff_view.show_file(s.current_file_idx)
      end
    end

    if is_valid_window(current_win) then
      pcall(vim.api.nvim_set_current_win, current_win)
    end
  end)

  if not ok then
    return false
  end

  setup_lifecycle_autocmds(active_session_id, s.windows.explorer, s.windows.diff, s.buffers.explorer, s.buffers.diff)
  return M.is_open()
end

local function schedule_external_teardown(session_id)
  if teardown_in_progress or teardown_scheduled then
    return
  end

  teardown_scheduled = true

  vim.schedule(function()
    if session_id ~= active_session_id then
      teardown_scheduled = false
      return
    end

    teardown_scheduled = false

    local s = state.get()
    if not has_layout_state(s) or M.is_open() then
      return
    end

    if blocked_close_session_id == session_id then
      blocked_close_session_id = nil
      if restore_blocked_layout() then
        return
      end
    end

    if is_valid_tab(s.tab) then
      M.close(true)
      return
    end

    require("codereview.ui.diff_view").clear()
    finalize_close(s.prev_win)
  end)
end

setup_lifecycle_autocmds = function(session_id, explorer_win, diff_win, explorer_buf, diff_buf)
  clear_lifecycle_autocmds()

  vim.api.nvim_create_autocmd("TabClosed", {
    group = lifecycle_group,
    callback = function()
      schedule_external_teardown(session_id)
    end,
  })

  for _, win in ipairs({ explorer_win, diff_win }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = lifecycle_group,
      pattern = tostring(win),
      callback = function()
        schedule_external_teardown(session_id)
      end,
    })
end

  for _, buf in ipairs({ explorer_buf, diff_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = lifecycle_group,
      buffer = buf,
      callback = function()
        schedule_external_teardown(session_id)
      end,
    })
  end
end

-- Create the two-panel layout: explorer (left) + diff (right)
function M.create()
  local s = state.get()
  local cfg = config.options

  active_session_id = active_session_id + 1
  blocked_close_session_id = nil
  teardown_in_progress = false
  teardown_scheduled = false

  -- Save current window to restore on close
  s.prev_win = vim.api.nvim_get_current_win()

  -- Create a new tab for the review
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()

  -- Create explorer buffer (left panel)
  local explorer_buf = create_explorer_buffer()

  -- Set current window to use explorer buffer
  local explorer_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(explorer_win, explorer_buf)

  -- Create diff window (right panel) via vertical split
  vim.cmd("rightbelow vsplit")
  local diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("winfixwidth", true, { win = explorer_win })
  vim.api.nvim_set_option_value("winfixwidth", false, { win = diff_win })
  vim.api.nvim_win_set_width(explorer_win, cfg.explorer_width)

  -- Create diff buffer
  local diff_buf = create_diff_buffer()
  vim.api.nvim_win_set_buf(diff_win, diff_buf)

  -- Window options
  for _, win in ipairs({ explorer_win, diff_win }) do
    configure_panel_window(win)
  end

  -- Store IDs in state
  s.windows.explorer = explorer_win
  s.windows.diff = diff_win
  s.buffers.explorer = explorer_buf
  s.buffers.diff = diff_buf

  setup_lifecycle_autocmds(active_session_id, explorer_win, diff_win, explorer_buf, diff_buf)

  -- Focus explorer
  vim.api.nvim_set_current_win(explorer_win)

  return {
    explorer_win = explorer_win,
    explorer_buf = explorer_buf,
    diff_win = diff_win,
    diff_buf = diff_buf,
  }
end

-- Close the layout and clean up
function M.close(force)
  force = force or false

  local s = state.get()
  if not has_layout_state(s) then
    return false
  end

  local review_tab = s.tab
  local prev_win = s.prev_win
  teardown_in_progress = true

  require("codereview.ui.diff_view").clear()

  -- In difftool mode: exit Neovim completely (tabclose fails on single-tab)
  if s.mode == "difftool" then
    finalize_close(prev_win)
    pcall(vim.cmd, force and "qa!" or "qa")
    return true
  end

  local closed = not is_valid_tab(review_tab)

  if is_valid_tab(review_tab) then
    local tab_number = vim.api.nvim_tabpage_get_number(review_tab)
    local close_cmd = force and ("tabclose! %d"):format(tab_number) or ("tabclose %d"):format(tab_number)
    local ok = pcall(vim.cmd, close_cmd)
    closed = ok or not is_valid_tab(review_tab)
  end

  if not closed and force then
    closed = dismantle_review_tab(review_tab, { s.buffers.explorer, s.buffers.diff })
  end

  if not closed then
    teardown_in_progress = false
    return false
  end

  finalize_close(prev_win)
  return true
end

-- Close safely, warning if there are unsaved notes
function M.safe_close(force)
  local s = state.get()
  if not force and s.notes_dirty then
    vim.notify(
      "E37: Review has unsaved notes. Use :q! to force or <C-s> to save.",
      vim.log.levels.WARN
    )
    return false
  end
  return M.close(force)
end

-- Intercept :w for a buffer → save_with_prompt (shows pre-generated name)
function M.setup_write_handlers(buf)
  clear_buffer_handler_autocmds(buf, "BufWriteCmd")

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = buffer_handlers_group,
    buffer = buf,
    callback = function()
      require("codereview.review.exporter").save_with_prompt()
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
    end,
  })
end

-- Intercept :q / :q! for a buffer so they close the whole plugin layout
function M.setup_quit_handlers(buf)
  clear_buffer_handler_autocmds(buf, "QuitPre")

  vim.api.nvim_create_autocmd("QuitPre", {
    group = buffer_handlers_group,
    buffer = buf,
    callback = function()
      if teardown_in_progress then
        return
      end

      local current_win = vim.api.nvim_get_current_win()
      local should_restore_layout = vim.v.cmdbang ~= 1 and state.get().notes_dirty

      if should_restore_layout then
        blocked_close_session_id = active_session_id
      end

      vim.v.event.abort = true
      local closed = M.safe_close(vim.v.cmdbang == 1)

      if closed then
        blocked_close_session_id = nil
      end

      if not closed and is_valid_window(current_win) then
        pcall(vim.api.nvim_set_current_win, current_win)
      end
    end,
  })
end

-- Check if layout is open
function M.is_open()
  local s = state.get()

  if not is_valid_tab(s.tab) then
    return false
  end

  if not is_valid_window(s.windows.explorer) or not is_valid_window(s.windows.diff) then
    return false
  end

  if not is_valid_buffer(s.buffers.explorer) or not is_valid_buffer(s.buffers.diff) then
    return false
  end

  if not window_belongs_to_tab(s.windows.explorer, s.tab) then
    return false
  end

  if not window_belongs_to_tab(s.windows.diff, s.tab) then
    return false
  end

  return true
end

-- Focus the explorer window
function M.focus_explorer()
  local s = state.get()
  if s.windows.explorer and vim.api.nvim_win_is_valid(s.windows.explorer) then
    vim.api.nvim_set_current_win(s.windows.explorer)
  end
end

-- Focus the diff window
function M.focus_diff()
  local s = state.get()
  if s.windows.diff and vim.api.nvim_win_is_valid(s.windows.diff) then
    vim.api.nvim_set_current_win(s.windows.diff)
  end
end

return M
