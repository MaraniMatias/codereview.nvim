local M = {}
local config = require("codereview.config")
local state = require("codereview.state")
local valid = require("codereview.util.validate")
local buf_util = require("codereview.util.buf")
local factory = require("codereview.ui.layout.factory")

local lifecycle_group = vim.api.nvim_create_augroup("CodeReviewLayoutLifecycle", { clear = false })
local buffer_handlers_group = vim.api.nvim_create_augroup("CodeReviewBufferHandlers", { clear = false })
local active_session_id = 0
local blocked_close_session_id = nil
local saved_statusline = nil  -- saved statusline to restore on close
local teardown_in_progress = false
local teardown_scheduled = false
local write_in_progress = false
local pending_close_after_save = false
local setup_lifecycle_autocmds

local function has_layout_state(s)
  return s.tab ~= nil
    or s.windows.explorer ~= nil
    or s.windows.diff ~= nil
    or s.windows.diff_old ~= nil
    or s.windows.diff_new ~= nil
    or s.buffers.explorer ~= nil
    or s.buffers.diff ~= nil
    or s.buffers.diff_old ~= nil
    or s.buffers.diff_new ~= nil
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

local create_explorer_buffer = factory.create_explorer_buffer
local create_diff_buffer = factory.create_diff_buffer
local create_diff_old_buffer = factory.create_diff_old_buffer
local create_diff_new_buffer = factory.create_diff_new_buffer
local configure_panel_window = factory.configure_panel_window
local compute_layout = factory.compute_layout

local function restore_previous_window(prev_win)
  if valid.win(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

local function call_in_tab(tab, callback)
  if not valid.tab(tab) then
    return false
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local ok, result = pcall(function()
    if current_tab ~= tab then
      vim.api.nvim_set_current_tabpage(tab)
    end

    return callback()
  end)

  if current_tab ~= tab and valid.tab(current_tab) then
    pcall(vim.api.nvim_set_current_tabpage, current_tab)
  end

  return ok, result
end

local function dismantle_review_tab(review_tab, buffers)
  if not valid.tab(review_tab) then
    return true
  end

  -- build a set of our own buffers so we only close windows that belong
  -- to the plugin, leaving windows from other plugins or user splits untouched.
  local our_bufs = {}
  for _, buf in ipairs(buffers) do
    our_bufs[buf] = true
  end

  local ok = call_in_tab(review_tab, function()
    local wins = vim.api.nvim_tabpage_list_wins(review_tab)

    for idx = #wins, 2, -1 do
      local win = wins[idx]
      if valid.win(win) then
        local win_buf = vim.api.nvim_win_get_buf(win)
        -- only close if the window holds one of our buffers or has a
        -- codereview:// buffer name
        local buf_name = vim.api.nvim_buf_get_name(win_buf)
        if our_bufs[win_buf] or buf_name:match("^codereview://") then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end

    vim.cmd("enew")
  end)

  if not ok then
    return false
  end

  for _, buf in ipairs(buffers) do
    if valid.buf(buf) then
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
  -- restore original statusline
  if saved_statusline ~= nil then
    vim.o.statusline = saved_statusline
    saved_statusline = nil
  end
  restore_previous_window(prev_win)
end

local function restore_blocked_layout()
  local s = state.get()
  if not valid.tab(s.tab) then
    return false
  end

  local explorer_missing = not valid.win(s.windows.explorer) or not valid.buf(s.buffers.explorer)

  local diff_missing
  if config.is_split_mode() then
    diff_missing = not valid.win(s.windows.diff_old) or not valid.buf(s.buffers.diff_old)
      or not valid.win(s.windows.diff_new) or not valid.buf(s.buffers.diff_new)
  else
    diff_missing = not valid.win(s.windows.diff) or not valid.buf(s.buffers.diff)
  end

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
      if config.is_split_mode() then
        local old_buf = create_diff_old_buffer()
        local old_win = vim.api.nvim_open_win(old_buf, false, {
          relative = "editor",
          row = dims.diff_old.row, col = dims.diff_old.col,
          width = dims.diff_old.width, height = dims.diff_old.height,
          style = "minimal", border = cfg.border,
          title = cfg.diff_title, title_pos = "center",
          focusable = true, zindex = 10,
        })
        local new_buf = create_diff_new_buffer()
        local new_win = vim.api.nvim_open_win(new_buf, false, {
          relative = "editor",
          row = dims.diff_new.row, col = dims.diff_new.col,
          width = dims.diff_new.width, height = dims.diff_new.height,
          style = "minimal", border = cfg.border,
          title = cfg.diff_title, title_pos = "center",
          focusable = true, zindex = 10,
        })
        for _, w in ipairs({ old_win, new_win }) do
          configure_panel_window(w)
          buf_util.set_win_options(w, { scrollbind = true, cursorbind = true })
        end
        s.windows.diff_old = old_win
        s.windows.diff_new = new_win
        s.buffers.diff_old = old_buf
        s.buffers.diff_new = new_buf
        diff_view.setup_keymaps(old_buf)
        diff_view.setup_keymaps(new_buf)
        -- re-sync scroll state after recreating split panels
        pcall(vim.cmd, "syncbind")
      else
        local diff_buf = create_diff_buffer()
        local diff_win = vim.api.nvim_open_win(diff_buf, false, {
          relative = "editor",
          row = dims.diff.row, col = dims.diff.col,
          width = dims.diff.width, height = dims.diff.height,
          style = "minimal", border = cfg.border,
          title = cfg.diff_title, title_pos = "center",
          focusable = true, zindex = 10,
        })
        configure_panel_window(diff_win)
        s.windows.diff = diff_win
        s.buffers.diff = diff_buf
        diff_view.setup_keymaps(diff_buf)
      end
      if #s.files > 0 then
        diff_view.show_file(s.current_file_idx)
      end
    end

    if valid.win(current_win) then
      pcall(vim.api.nvim_set_current_win, current_win)
    end
  end)

  if not ok then
    return false
  end

  M._setup_current_lifecycle_autocmds()
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

    -- A :wq save is in progress – let the save callback handle the close.
    if write_in_progress then
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

    if valid.tab(s.tab) then
      M.close(true)
      return
    end

    require("codereview.ui.diff_view").clear()
    finalize_close(s.prev_win)
  end)
end

setup_lifecycle_autocmds = function(session_id, wins, bufs)
  clear_lifecycle_autocmds()

  vim.api.nvim_create_autocmd("TabClosed", {
    group = lifecycle_group,
    callback = function()
      schedule_external_teardown(session_id)
    end,
  })

  for _, win in ipairs(wins) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = lifecycle_group,
      pattern = tostring(win),
      callback = function()
        schedule_external_teardown(session_id)
      end,
    })
  end

  for _, buf in ipairs(bufs) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = lifecycle_group,
      buffer = buf,
      callback = function()
        schedule_external_teardown(session_id)
      end,
    })
  end

  -- guard resize callback with session_id to prevent stale autocmds
  -- from a previous session from firing.
  vim.api.nvim_create_autocmd("VimResized", {
    group = lifecycle_group,
    callback = function()
      if session_id ~= active_session_id then return end
      M.resize()
    end,
  })
end

-- Helper to collect current windows/buffers and setup lifecycle autocmds
function M._setup_current_lifecycle_autocmds()
  local s = state.get()
  local wins = { s.windows.explorer }
  local bufs = { s.buffers.explorer }
  if config.is_split_mode() then
    table.insert(wins, s.windows.diff_old)
    table.insert(wins, s.windows.diff_new)
    table.insert(bufs, s.buffers.diff_old)
    table.insert(bufs, s.buffers.diff_new)
  else
    table.insert(wins, s.windows.diff)
    table.insert(bufs, s.buffers.diff)
  end
  setup_lifecycle_autocmds(active_session_id, wins, bufs)
end

-- Create the panel layout as floating windows
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
  -- save the original statusline before overwriting
  saved_statusline = vim.o.statusline
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
  configure_panel_window(explorer_win)
  s.windows.explorer = explorer_win
  s.buffers.explorer = explorer_buf

  local result = {
    explorer_win = explorer_win,
    explorer_buf = explorer_buf,
  }

  if config.is_split_mode() then
    -- Split mode: create two diff panels (old + new)
    local diff_old_buf = create_diff_old_buffer()
    local diff_old_win = vim.api.nvim_open_win(diff_old_buf, false, {
      relative = "editor",
      row = dims.diff_old.row,
      col = dims.diff_old.col,
      width = dims.diff_old.width,
      height = dims.diff_old.height,
      style = "minimal",
      border = cfg.border,
      title = cfg.diff_title,
      title_pos = "center",
      focusable = true,
      zindex = 10,
    })

    local diff_new_buf = create_diff_new_buffer()
    local diff_new_win = vim.api.nvim_open_win(diff_new_buf, true, {
      relative = "editor",
      row = dims.diff_new.row,
      col = dims.diff_new.col,
      width = dims.diff_new.width,
      height = dims.diff_new.height,
      style = "minimal",
      border = cfg.border,
      title = cfg.diff_title,
      title_pos = "center",
      focusable = true,
      zindex = 10,
    })

    for _, win in ipairs({ diff_old_win, diff_new_win }) do
      configure_panel_window(win)
      buf_util.set_win_options(win, { scrollbind = true, cursorbind = true })
    end

    s.windows.diff_old = diff_old_win
    s.windows.diff_new = diff_new_win
    s.buffers.diff_old = diff_old_buf
    s.buffers.diff_new = diff_new_buf

    result.diff_old_win = diff_old_win
    result.diff_old_buf = diff_old_buf
    result.diff_new_win = diff_new_win
    result.diff_new_buf = diff_new_buf
  else
    -- Unified mode: single diff panel
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
    configure_panel_window(diff_win)

    s.windows.diff = diff_win
    s.buffers.diff = diff_buf

    result.diff_win = diff_win
    result.diff_buf = diff_buf
  end

  M._setup_current_lifecycle_autocmds()

  -- Focus explorer
  vim.api.nvim_set_current_win(explorer_win)

  return result
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
  if config.is_split_mode() then
    vim.api.nvim_win_set_config(s.windows.diff_old, {
      relative = "editor",
      row = dims.diff_old.row, col = dims.diff_old.col,
      width = dims.diff_old.width, height = dims.diff_old.height,
    })
    vim.api.nvim_win_set_config(s.windows.diff_new, {
      relative = "editor",
      row = dims.diff_new.row, col = dims.diff_new.col,
      width = dims.diff_new.width, height = dims.diff_new.height,
    })
  else
    vim.api.nvim_win_set_config(s.windows.diff, {
      relative = "editor",
      row = dims.diff.row, col = dims.diff.col,
      width = dims.diff.width, height = dims.diff.height,
    })
  end

  -- re-render content so virtual text, truncation lines, treesitter
  -- highlights, and explorer layout stay in sync with the new dimensions.
  local diff_view = require("codereview.ui.diff_view")
  diff_view.refresh_notes()
  require("codereview.ui.explorer.view").render()
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

  for _, key in ipairs({ "diff", "diff_old", "diff_new", "explorer" }) do
    local win = s.windows[key]
    if valid.win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- In difftool mode: exit Neovim completely (tabclose fails on single-tab)
  if s.mode == "difftool" then
    -- teardown_in_progress must stay true while qa runs so that
    -- QuitPre handlers on the plugin buffers return early instead
    -- of aborting the quit.  finalize_close resets the flag, so
    -- call it AFTER qa (it is only reached if qa fails for some reason).
    -- In single-file difftool mode, use cq! (exit code 1) so git stops
    -- iterating over remaining files.
    if s.single_file_difftool then
      pcall(vim.cmd, "cq!")
    else
      -- Try tabclose first to avoid discarding external buffers (L03 fix).
      -- Only fall back to qa/qa! if we're on the last tab.
      local tabs = vim.api.nvim_list_tabpages()
      if #tabs > 1 then
        pcall(vim.cmd, force and "tabclose!" or "tabclose")
      else
        pcall(vim.cmd, force and "qa!" or "qa")
      end
    end
    finalize_close(prev_win)
    return true
  end

  local closed = not valid.tab(review_tab)

  if valid.tab(review_tab) then
    local tab_number = vim.api.nvim_tabpage_get_number(review_tab)
    local close_cmd = force and ("tabclose! %d"):format(tab_number) or ("tabclose %d"):format(tab_number)
    local ok = pcall(vim.cmd, close_cmd)
    closed = ok or not valid.tab(review_tab)
  end

  if not closed and force then
    local bufs_to_dismantle = { s.buffers.explorer }
    if s.buffers.diff then table.insert(bufs_to_dismantle, s.buffers.diff) end
    if s.buffers.diff_old then table.insert(bufs_to_dismantle, s.buffers.diff_old) end
    if s.buffers.diff_new then table.insert(bufs_to_dismantle, s.buffers.diff_new) end
    closed = dismantle_review_tab(review_tab, bufs_to_dismantle)
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
  return M.close(true)
end

-- Intercept :w for a buffer → save_with_prompt (shows pre-generated name)
function M.setup_write_handlers(buf)
  clear_buffer_handler_autocmds(buf, "BufWriteCmd")

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = buffer_handlers_group,
    buffer = buf,
    callback = function()
      write_in_progress = true
      require("codereview.review.exporter").save_with_prompt(function(success)
        write_in_progress = false
        if pending_close_after_save then
          pending_close_after_save = false
          if success then
            M.close(true)
          elseif not M.is_open() then
            -- Layout was destroyed while the prompt was open (quit
            -- proceeded despite abort attempt). Clean up state.
            M.close(true)
          end
        end
      end)
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

      if write_in_progress then
        vim.v.event.abort = true
        pending_close_after_save = true
        return
      end

      local force = vim.v.cmdbang == 1
      local current_win = vim.api.nvim_get_current_win()

      if not force and state.get().notes_dirty then
        vim.v.event.abort = true
        blocked_close_session_id = active_session_id
        M.safe_close(false)
        if valid.win(current_win) then
          pcall(vim.api.nvim_set_current_win, current_win)
        end
        return
      end

      -- If the plugin state was already cleaned up (e.g. after a partially
      -- failed close), don't abort the quit – let Neovim close normally.
      if not has_layout_state(state.get()) then
        return
      end

      vim.v.event.abort = true
      local closed = M.safe_close(force)
      if not closed and valid.win(current_win) then
        pcall(vim.api.nvim_set_current_win, current_win)
      end
    end,
  })
end

-- Check if layout is open
function M.is_open()
  local s = state.get()

  if not valid.tab(s.tab) then
    return false
  end

  if not valid.win(s.windows.explorer) or not valid.buf(s.buffers.explorer) then
    return false
  end

  if not valid.win_in_tab(s.windows.explorer, s.tab) then
    return false
  end

  if config.is_split_mode() then
    if not valid.win(s.windows.diff_old) or not valid.buf(s.buffers.diff_old) then
      return false
    end
    if not valid.win(s.windows.diff_new) or not valid.buf(s.buffers.diff_new) then
      return false
    end
    if not valid.win_in_tab(s.windows.diff_old, s.tab) then
      return false
    end
    if not valid.win_in_tab(s.windows.diff_new, s.tab) then
      return false
    end
  else
    if not valid.win(s.windows.diff) or not valid.buf(s.buffers.diff) then
      return false
    end
    if not valid.win_in_tab(s.windows.diff, s.tab) then
      return false
    end
  end

  return true
end

-- Focus the explorer window
function M.focus_explorer()
  local s = state.get()
  if valid.win(s.windows.explorer) then
    vim.api.nvim_set_current_win(s.windows.explorer)
  end
end

-- Focus the diff window (in split mode, focus the old/left panel first)
function M.focus_diff()
  local s = state.get()
  if config.is_split_mode() then
    if valid.win(s.windows.diff_old) then
      vim.api.nvim_set_current_win(s.windows.diff_old)
    end
  else
    if valid.win(s.windows.diff) then
      vim.api.nvim_set_current_win(s.windows.diff)
    end
  end
end

-- Focus the new/right diff panel (split mode only)
function M.focus_diff_new()
  local s = state.get()
  if valid.win(s.windows.diff_new) then
    vim.api.nvim_set_current_win(s.windows.diff_new)
  end
end

function M.is_split_mode()
  return config.is_split_mode()
end

-- Check if the current window is the old/left diff panel
function M.is_diff_old_focused()
  local s = state.get()
  return s.windows.diff_old and vim.api.nvim_get_current_win() == s.windows.diff_old
end

return M
