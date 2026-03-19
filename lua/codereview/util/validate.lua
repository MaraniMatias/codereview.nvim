local M = {}

function M.win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

function M.tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

function M.win_in_tab(win, tab)
  return M.win(win) and M.tab(tab) and vim.api.nvim_win_get_tabpage(win) == tab
end

return M
