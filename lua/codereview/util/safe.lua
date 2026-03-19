local M = {}

function M.pcall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    vim.schedule(function()
      vim.notify("codereview: " .. tostring(err), vim.log.levels.DEBUG)
    end)
  end
  return ok, err
end

return M
