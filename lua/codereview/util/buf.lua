local M = {}

function M.set_options(buf, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { buf = buf })
  end
end

function M.set_win_options(win, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { win = win })
  end
end

function M.create(name, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  M.set_options(buf, vim.tbl_extend("force", {
    buftype = "acwrite",
    bufhidden = "wipe",
    swapfile = false,
    modifiable = false,
  }, opts))
  return buf
end

function M.set_lines(buf, lines)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
