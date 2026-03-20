local M = {}
local store = require("codereview.notes.store")
local config = require("codereview.config")
local valid = require("codereview.util.validate")

-- Currently open float context
local float_ctx = nil
-- Re-entry guard: true while close/confirm is running
local closing = false
-- Re-entry guard: true while ask_save_or_discard prompt is visible
local asking = false

-- Ask user whether to save, discard, or delete the current note.
-- Shows options in the float footer and waits for a single keypress.
-- When editing an existing note, also offers "delete".
-- Esc on the prompt returns to editing as if nothing happened.
function M.ask_save_or_discard()
  if not float_ctx or asking then return end
  asking = true
  local ctx = float_ctx
  local lines = vim.api.nvim_buf_get_lines(ctx.note_buf, 0, -1, false)
  local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    asking = false
    M.close()
    return
  end

  -- Show options in the float footer
  local footer = ctx.is_edit
    and " Save? (y)es · (n)o · (d)iscard · <Esc> cancel "
    or  " Save? (y)es · (n)o · <Esc> cancel "
  if valid.win(ctx.note_win) then
    vim.api.nvim_win_set_config(ctx.note_win, { footer = footer, footer_pos = "center" })
    vim.cmd("redraw")
  end

  local ok, ch = pcall(vim.fn.getcharstr)
  -- Restore footer (remove it)
  if valid.win(ctx.note_win) then
    vim.api.nvim_win_set_config(ctx.note_win, { footer = "", footer_pos = "center" })
    vim.cmd("redraw")
  end

  asking = false
  if not ok or ch == "\27" then
    -- Esc or error → return to editing
    return
  end

  local key = ch:lower()
  if key == "y" or ch == "\r" then
    M.confirm()
  elseif key == "n" then
    M.close()
  elseif key == "d" and ctx.is_edit then
    -- Clear buffer and confirm — empty text triggers deletion in store
    if float_ctx then
      vim.api.nvim_set_option_value("modifiable", true, { buf = float_ctx.note_buf })
      vim.api.nvim_buf_set_lines(float_ctx.note_buf, 0, -1, false, { "" })
    end
    M.confirm()
  end
  -- Any other key → do nothing, return to editing
end

-- Open the note floating window
-- filepath: file being annotated
-- line_start, line_end: line range
-- code: code context string
-- existing_text: text for editing existing note (nil for new)
function M.open(filepath, line_start, line_end, code, existing_text, side)
  if float_ctx then
    M.close()
  end

  side = side or "new"

  -- Detect language from filepath
  local ext = filepath:match("%.([^%.]+)$") or ""

  -- Build top buffer content (context: file title + selected code)
  local side_label = side == "old" and " (deleted)" or ""
  local top_lines = {}

  -- show line numbers in code context block for reference
  if code and code ~= "" then
    table.insert(top_lines, "```" .. ext)
    local code_lnum = line_start
    for line in (code .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(top_lines, string.format("%d │ %s", code_lnum, line))
      code_lnum = code_lnum + 1
    end
    table.insert(top_lines, "```")
  end

  -- Build top window title
  local top_title = " " .. filepath .. " L" .. line_start ..
    (line_end and line_end ~= line_start and ("-" .. line_end) or "") .. side_label .. " "

  -- Build note buffer content
  local note_lines = existing_text and vim.split(existing_text, "\n") or { "" }

  -- Calculate window size and position
  -- configurable float width instead of hardcoded 80
  local ui = vim.api.nvim_list_uis()[1]
  local max_width = config.options.note_float_width or 80
  local width = math.min(max_width, ui.width - 10)
  local total_height = math.min(30, ui.height - 6)
  local col = math.floor((ui.width - width) / 2)

  -- Top window height: dynamic based on content, clamped to max 50% of total
  local top_content_height = math.max(1, #top_lines)
  local top_height = math.min(top_content_height, math.floor(total_height * 0.5))

  -- Bottom window height: remaining space (min 5 lines)
  -- Account for borders: each window has 2 border rows (top + bottom)
  local bottom_height = math.max(5, total_height - top_height - 2)

  -- Vertical centering based on combined height (including borders)
  local combined_height = top_height + 2 + bottom_height + 2
  local start_row = math.max(0, math.floor((ui.height - combined_height) / 2))

  local top_row = start_row
  local bottom_row = start_row + top_height + 2  -- +2 for top window border

  -- Create top buffer (read-only context)
  local top_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = top_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = top_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = top_buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = top_buf })
  vim.api.nvim_buf_set_lines(top_buf, 0, -1, false, top_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = top_buf })

  -- use the plugin's configured border style instead of hardcoded "rounded"
  local border = config.options.border or "rounded"

  -- Create top floating window (not focused)
  local top_win = vim.api.nvim_open_win(top_buf, false, {
    relative = "editor",
    width = width,
    height = top_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = border,
    title = top_title,
    title_pos = "center",
    focusable = false,
    zindex = 50,
  })

  vim.api.nvim_set_option_value("wrap", true, { win = top_win })
  vim.api.nvim_set_option_value("number", false, { win = top_win })

  -- Create note buffer (editable)
  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = note_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = note_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = note_buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = note_buf })
  vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, note_lines)

  -- Create note floating window (focused)
  local note_title = existing_text and " Edit Note " or " Note "
  local note_win = vim.api.nvim_open_win(note_buf, true, {
    relative = "editor",
    width = width,
    height = bottom_height,
    row = bottom_row,
    col = col,
    style = "minimal",
    border = border,
    title = note_title,
    title_pos = "center",
    zindex = 50,
  })

  vim.api.nvim_set_option_value("wrap", true, { win = note_win })
  vim.api.nvim_set_option_value("number", true, { win = note_win })

  -- Position cursor and enter insert mode
  vim.api.nvim_win_set_cursor(note_win, { 1, 0 })
  vim.cmd("startinsert!")

  float_ctx = {
    top_buf = top_buf,
    top_win = top_win,
    note_buf = note_buf,
    note_win = note_win,
    filepath = filepath,
    line_start = line_start,
    line_end = line_end,
    code = code,
    side = side,
    is_edit = existing_text ~= nil,
  }

  -- Clean up float_ctx if Neovim closes either window externally (:qa, etc.)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(note_win),
    once = true,
    callback = function()
      if float_ctx and float_ctx.note_win == note_win then
        -- Close top window too if still valid
        if valid.win(top_win) then
          vim.api.nvim_win_close(top_win, true)
        end
        float_ctx = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(top_win),
    once = true,
    callback = function()
      if float_ctx and float_ctx.top_win == top_win then
        -- Close note window too if still valid
        if valid.win(note_win) then
          vim.api.nvim_win_close(note_win, true)
        end
        float_ctx = nil
      end
    end,
  })

  -- BufWriteCmd: handle :w and :wq — save the note to the store.
  -- buftype=acwrite requires this; without it :w errors with E676.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = note_buf,
    callback = function()
      M.confirm()
    end,
  })

  -- QuitPre: intercept :q and :q! so the note isn't lost silently.
  -- Uses vim.v.event.abort (same pattern as layout quit handlers) to cancel
  -- the quit, then shows the save/discard prompt synchronously.
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = note_buf,
    callback = function()
      if float_ctx and not closing then
        vim.v.event.abort = true
        M.ask_save_or_discard()
      end
    end,
  })

  -- Keymaps (on note buffer only)
  local opts = { noremap = true, silent = true, buffer = note_buf }

  -- Esc in insert mode: exit insert then ask save/discard
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd("stopinsert")
    vim.schedule(M.ask_save_or_discard)
  end, opts)

  -- Esc in normal mode: ask save/discard
  vim.keymap.set("n", "<Esc>", function()
    M.ask_save_or_discard()
  end, opts)

  -- q in normal mode: ask save/discard (consistent with layout quit behavior)
  local km = config.options.keymaps
  vim.keymap.set("n", km.quit, function()
    M.ask_save_or_discard()
  end, opts)

  -- Autocmd to handle buffer leave — ask save/discard instead of silent close.
  -- NOTE: intentionally NOT once=true so that if the user cancels the prompt
  -- (Esc) and then navigates away again, they get another chance to save.
  -- The guards (float_ctx, closing, asking) prevent double-firing.
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = note_buf,
    callback = function()
      if float_ctx and not closing then
        vim.schedule(M.ask_save_or_discard)
      end
    end,
  })
end

-- Confirm the note (save it)
function M.confirm()
  if not float_ctx or closing then return end
  closing = true
  local ctx = float_ctx

  -- Get the note text (entire note buffer)
  local lines = vim.api.nvim_buf_get_lines(ctx.note_buf, 0, -1, false)
  local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    closing = false
    M.close()
    return
  end

  -- Save the note
  store.set(ctx.filepath, ctx.line_start, ctx.line_end, ctx.code, text, ctx.side)

  -- Close both floats
  float_ctx = nil
  for _, win in ipairs({ ctx.note_win, ctx.top_win }) do
    if valid.win(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Refresh displays
  -- Auto-expand file in explorer so the new note is immediately visible
  local s = require("codereview.state").get()
  for _, file in ipairs(s.files) do
    if file.path == ctx.filepath then
      file.expanded = true
      break
    end
  end

  require("codereview.ui.diff_view").refresh_notes()
  require("codereview.ui.explorer").render()

  closing = false

  -- Restore focus to diff view so cursor doesn't get trapped
  require("codereview.ui.layout").focus_diff()

  -- use nvim_echo for consistency with the rest of the plugin
  local side_suffix = ctx.side == "old" and " (deleted)" or ""
  vim.api.nvim_echo(
    { { "CodeReview: note saved for L" .. ctx.line_start .. side_suffix, "Comment" } },
    false, {}
  )
end

function M.is_open()
  return float_ctx ~= nil
    and float_ctx.note_win ~= nil
    and valid.win(float_ctx.note_win)
end

-- Close without saving
function M.close()
  if not float_ctx or closing then return end
  closing = true
  local ctx = float_ctx
  float_ctx = nil
  for _, win in ipairs({ ctx.note_win, ctx.top_win }) do
    if valid.win(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  closing = false

  -- Restore focus to diff view so cursor doesn't get trapped
  require("codereview.ui.layout").focus_diff()
end

return M
