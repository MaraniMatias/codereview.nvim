local M = {}
local store = require("codereview.notes.store")

-- Currently open float context
local float_ctx = nil

-- Open the note floating window
-- filepath: file being annotated
-- line_start, line_end: line range
-- code: code context string
-- existing_text: text for editing existing note (nil for new)
function M.open(filepath, line_start, line_end, code, existing_text)
  if float_ctx then
    M.close()
  end

  -- Detect language from filepath
  local ext = filepath:match("%.([^%.]+)$") or ""

  -- Build buffer content
  local header_lines = {
    "# Note — " .. filepath .. " L" .. line_start ..
      (line_end and line_end ~= line_start and ("-" .. line_end) or ""),
    "",
  }

  local code_lines = {}
  if code and code ~= "" then
    table.insert(code_lines, "```" .. ext)
    for line in (code .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(code_lines, line)
    end
    table.insert(code_lines, "```")
    table.insert(code_lines, "")
  end

  local separator = { "---", "" }
  local note_lines = existing_text and vim.split(existing_text, "\n") or { "" }

  local all_lines = {}
  for _, l in ipairs(header_lines) do table.insert(all_lines, l) end
  for _, l in ipairs(code_lines) do table.insert(all_lines, l) end
  for _, l in ipairs(separator) do table.insert(all_lines, l) end
  for _, l in ipairs(note_lines) do table.insert(all_lines, l) end

  -- Calculate where the editable area starts (after separator)
  local edit_start_line = #header_lines + #code_lines + #separator + 1

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  -- Calculate window size and position
  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(80, ui.width - 10)
  local height = math.min(30, ui.height - 6)
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Add Note ",
    title_pos = "center",
    footer = " w save  ·  <Esc> save?  ·  q cancel ",
    footer_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("number", true, { win = win })

  -- Position cursor at the editable area
  vim.api.nvim_win_set_cursor(win, { edit_start_line, 0 })
  vim.cmd("startinsert!")

  float_ctx = {
    buf = buf,
    win = win,
    filepath = filepath,
    line_start = line_start,
    line_end = line_end,
    code = code,
    edit_start_line = edit_start_line,
  }

  -- Clean up float_ctx if Neovim closes the window externally (:qa, etc.)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      float_ctx = nil
    end,
  })

  -- Keymaps
  local opts = { noremap = true, silent = true, buffer = buf }

  local function ask_save_or_discard()
    if not float_ctx then return end
    local ctx = float_ctx
    local lines = vim.api.nvim_buf_get_lines(ctx.buf, ctx.edit_start_line - 1, -1, false)
    local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      M.close()
      return
    end
    local choice = vim.fn.confirm("Save note?", "&Yes\n&No\n&Cancel", 1)
    if choice == 1 then
      M.confirm()
    elseif choice == 2 then
      M.close()
    end
    -- 0 or 3 (Cancel): stay in float
  end

  -- Save with w (like :w in vim), normal mode only
  vim.keymap.set("n", "w", function()
    M.confirm()
  end, opts)

  -- Esc in insert mode: exit insert then ask save/discard
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd("stopinsert")
    vim.schedule(ask_save_or_discard)
  end, opts)

  -- Esc in normal mode: ask save/discard
  vim.keymap.set("n", "<Esc>", function()
    ask_save_or_discard()
  end, opts)

  -- q: discard without asking
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)

  -- Autocmd to close on buffer leave
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if float_ctx then
        M.close()
      end
    end,
  })
end

-- Confirm the note (save it)
function M.confirm()
  if not float_ctx then return end
  local ctx = float_ctx

  -- Get the note text (lines after the separator)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, ctx.edit_start_line - 1, -1, false)
  local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    M.close()
    return
  end

  -- Save the note
  store.set(ctx.filepath, ctx.line_start, ctx.line_end, ctx.code, text)

  -- Close float
  float_ctx = nil
  if vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true)
  end

  -- Refresh displays
  require("codereview.ui.diff_view").refresh_notes()
  require("codereview.ui.explorer").render()

  vim.notify("Note saved for L" .. ctx.line_start, vim.log.levels.INFO)
end

-- Close without saving
function M.close()
  if not float_ctx then return end
  local ctx = float_ctx
  float_ctx = nil
  if vim.api.nvim_win_is_valid(ctx.win) then
    vim.api.nvim_win_close(ctx.win, true)
  end
end

return M
