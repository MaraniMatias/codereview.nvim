local M = {}

--- Ask a yes/no confirmation in the cmdline.
--- Uses redraw + nvim_echo + getcharstr to bypass Noice/notification plugins.
--- Returns true for "y"/"Y", false for anything else (including Esc).
function M.confirm(message)
  vim.cmd("redraw")
  vim.api.nvim_echo({ { message .. " [y/n] ", "Question" } }, false, {})
  local ok, ch = pcall(vim.fn.getcharstr)
  vim.cmd("echo ''")
  if not ok then
    return false
  end
  return ch == "y" or ch == "Y"
end

--- Ask the user to choose from N options in the cmdline.
--- Each option is a table { key = "o", label = "overwrite", value = "overwrite" }.
--- Uses redraw + nvim_echo + getcharstr to bypass Noice/notification plugins.
--- Shows `message [y]es (save) / [n]o (discard)` and reads a single key.
--- Returns the `value` of the matched option, or nil on Esc / no match.
function M.choose(message, options)
  -- Build display: [k]label / [k]label / ...
  local parts = {}
  for _, opt in ipairs(options) do
    table.insert(parts, "[" .. opt.key .. "]" .. opt.label:sub(2))
  end
  local suffix = table.concat(parts, " / ")

  vim.cmd("redraw")
  vim.api.nvim_echo({
    { message .. " ", "Question" },
    { suffix .. " ", "MoreMsg" },
  }, false, {})

  local ok, ch = pcall(vim.fn.getcharstr)
  vim.cmd("echo ''")
  if not ok then
    return nil
  end

  -- Esc key (byte 27)
  if ch == "\27" then
    return nil
  end

  local lower = ch:lower()
  for _, opt in ipairs(options) do
    if lower == opt.key:lower() then
      return opt.value
    end
  end
  return nil
end

return M
