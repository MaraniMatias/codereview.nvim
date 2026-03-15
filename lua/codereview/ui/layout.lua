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
    wrap = false,
    cursorline = true,
  })
end

local function compute_layout()
  local cfg = config.options
  local total_w = vim.o.columns
  local total_h = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  local exp_w = cfg.explorer_width
  -- each bordered float uses 1 col on each side; place diff right after explorer's right border
  local diff_col = exp_w + 2
  local diff_w = total_w - diff_col - 2
  local h = total_h - 2  -- top + bottom border
  return {
    explorer = { row = 0, col = 0, width = math.max(exp_w, 10), height = math.max(h, 5) },
    diff = { row = 0, col = diff_col, width = math.max(diff_w, 20), height = math.max(h, 5) },
  }
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
    local dims = compute_layout()

    if explorer_missing then
      local explorer_buf = create_explorer_buffer()
      local explorer_win = vim.api.nvim_open_win(explorer_buf, false, {
        relative = "editor",
        row = dims.explorer.row,
        col = dims.explorer.col,
        width = dims.explorer.width,
        height = dims.explorer.height,
        style = "minimal",
        border = cfg.border,
        title = cfg.explorer_title,
        title_pos = "center",
        focusable = true,
        zindex = 10,
      })

      configure_panel_window(explorer_win)

      s.windows.explorer = explorer_win
      s.buffers.explorer = explorer_buf

      explorer.setup_keymaps(explorer_buf)
      explorer.render()
    end

    if diff_missing then
      local diff_buf = create_diff_buffer()
      local diff_win = vim.api.nvim_open_win(diff_buf, false, {
        relative = "editor",
        row = dims.diff.row,
        col = dims.diff.col,
        width = dims.diff.width,
        height = dims.diff.height,
        style = "minimal",
        border = cfg.border,
        title = cfg.diff_title,
        title_pos = "center",
        focusable = true,
        zindex = 10,
      })

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

  vim.api.nvim_create_autocmd("VimResized", {
    group = lifecycle_group,
    callback = function()
      M.resize()
    end,
  })
end

-- Create the two-panel layout: explorer (left) + diff (right) as floating windows
function M.create()
  local s = state.get()
  local cfg = config.options

  active_session_id = active_session_id + 1
  blocked_close_session_id = nil
  teardown_in_progress = false
  teardown_scheduled = false

  -- Save current window to restore on close
  s.prev_win = vim.api.nvim_get_current_win()

  -- Create a new tab for isolation; the base window gets a blank background buffer
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()
  local base_win = vim.api.nvim_get_current_win()
  local bg_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(base_win, bg_buf)
  vim.api.nvim_set_option_value("statusline", " ", { win = base_win })

  -- Compute float dimensions
  local dims = compute_layout()

  -- Create explorer float (left panel)
  local explorer_buf = create_explorer_buffer()
  local explorer_win = vim.api.nvim_open_win(explorer_buf, false, {
    relative = "editor",
    row = dims.explorer.row,
    col = dims.explorer.col,
    width = dims.explorer.width,
    height = dims.explorer.height,
    style = "minimal",
    border = cfg.border,
    title = cfg.explorer_title,
    title_pos = "center",
    focusable = true,
    zindex = 10,
  })

  -- Create diff float (right panel)
  local diff_buf = create_diff_buffer()
  local diff_win = vim.api.nvim_open_win(diff_buf, true, {
    relative = "editor",
    row = dims.diff.row,
    col = dims.diff.col,
    width = dims.diff.width,
    height = dims.diff.height,
    style = "minimal",
    border = cfg.border,
    title = cfg.diff_title,
    title_pos = "center",
    focusable = true,
    zindex = 10,
  })

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

-- Recompute and update float sizes (called on VimResized)
function M.resize()
  local s = state.get()
  if not M.is_open() then return end
  local dims = compute_layout()
  vim.api.nvim_win_set_config(s.windows.explorer, {
    relative = "editor",
    row = dims.explorer.row,
    col = dims.explorer.col,
    width = dims.explorer.width,
    height = dims.explorer.height,
  })
  vim.api.nvim_win_set_config(s.windows.diff, {
    relative = "editor",
    row = dims.diff.row,
    col = dims.diff.col,
    width = dims.diff.width,
    height = dims.diff.height,
  })
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
      "E37: Review has unsaved notes. Use :q! to force or :w to save.",
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
      if teardown_in_progress then return end

      local force = vim.v.cmdbang == 1
      local current_win = vim.api.nvim_get_current_win()

      if not force and state.get().notes_dirty then
        vim.v.event.abort = true
        blocked_close_session_id = active_session_id
        M.safe_close(false)
        if is_valid_window(current_win) then
          pcall(vim.api.nvim_set_current_win, current_win)
        end
        return
      end

      vim.v.event.abort = true
      local closed = M.safe_close(force)
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
