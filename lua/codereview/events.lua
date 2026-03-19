local M = {}

local handlers = {}

function M.on(event, handler)
  if not handlers[event] then
    handlers[event] = {}
  end
  table.insert(handlers[event], handler)
end

function M.emit(event, ...)
  for _, handler in ipairs(handlers[event] or {}) do
    handler(...)
  end
end

function M.clear()
  handlers = {}
end

return M
