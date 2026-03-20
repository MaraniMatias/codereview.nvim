local M = {}

--- Ask a yes/no confirmation via vim.fn.confirm().
--- Works with Noice (shown as interactive cmdline, not passive notification).
--- Returns true for "Yes", false for "No" or dismiss.
function M.confirm(message)
  local choice = vim.fn.confirm(message, "&Yes\n&No", 2, "Question")
  return choice == 1
end

--- Ask the user to choose from N options via vim.fn.confirm().
--- Each option is a table { key = "o", label = "overwrite", value = "overwrite" }.
--- Works with Noice (shown as interactive cmdline, not passive notification).
--- Returns the `value` of the chosen option, or nil on dismiss / no match.
function M.choose(message, options)
  local buttons = {}
  for _, opt in ipairs(options) do
    local label = opt.label
    local key_lower = opt.key:lower()
    local found = false
    local result = ""
    for i = 1, #label do
      local ch = label:sub(i, i)
      if not found and ch:lower() == key_lower then
        result = result .. "&" .. ch
        found = true
      else
        result = result .. ch
      end
    end
    if not found then
      result = "&" .. opt.key .. " " .. label
    end
    result = result:sub(1, 1):upper() .. result:sub(2)
    table.insert(buttons, result)
  end

  local choice = vim.fn.confirm(message, table.concat(buttons, "\n"), 1, "Question")
  if choice >= 1 and choice <= #options then
    return options[choice].value
  end
  return nil
end

return M
