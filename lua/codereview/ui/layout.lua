local M = {}
local config = require("codereview.config")
local state = require("codereview.state")

-- Create the two-panel layout: explorer (left) + diff (right)
function M.create()
  local s = state.get()
  local cfg = config.options

  -- Save current window to restore on close
  s.prev_win = vim.api.nvim_get_current_win()

  -- Create a new tab for the review
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()

  -- Create explorer buffer (left panel)
  local explorer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(explorer_buf, "codereview://explorer")
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = explorer_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = explorer_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = explorer_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = explorer_buf })
  vim.api.nvim_set_option_value("filetype", "codereview-explorer", { buf = explorer_buf })

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
  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(diff_buf, "codereview://diff")
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = diff_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = diff_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = diff_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = diff_buf })
  vim.api.nvim_win_set_buf(diff_win, diff_buf)

  -- Window options
  for _, win in ipairs({ explorer_win, diff_win }) do
    vim.api.nvim_set_option_value("number", false, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
    vim.api.nvim_set_option_value("wrap", false, { win = win })
    vim.api.nvim_set_option_value("cursorline", true, { win = win })
  end

  -- Store IDs in state
  s.windows.explorer = explorer_win
  s.windows.diff = diff_win
  s.buffers.explorer = explorer_buf
  s.buffers.diff = diff_buf

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
function M.close()
  require("codereview.ui.diff_view").clear()
  local s = state.get()
  if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) then
    vim.cmd("tabclose")
  end
  state.reset()
end

-- Close safely, warning if there are unsaved notes
function M.safe_close(force)
  local s = state.get()
  if not force and s.notes_dirty then
    vim.notify(
      "E37: Review has unsaved notes. Use :q! to force or <C-s> to save.",
      vim.log.levels.WARN
    )
    return
  end
  M.close()
end

-- Intercept :w for a buffer → save_with_prompt (shows pre-generated name)
function M.setup_write_handlers(buf)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      require("codereview.review.exporter").save_with_prompt()
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
    end,
  })
end

-- Intercept :q / :q! for a buffer so they close the whole plugin layout
function M.setup_quit_handlers(buf)
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
      vim.v.event.abort = true
      M.safe_close(vim.v.cmdbang == 1)
    end,
  })
end

-- Check if layout is open
function M.is_open()
  local s = state.get()
  return s.windows.explorer ~= nil
    and vim.api.nvim_win_is_valid(s.windows.explorer)
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
