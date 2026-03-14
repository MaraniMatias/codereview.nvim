local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")

-- Status icons
local STATUS_ICONS = {
  M = "[M]",
  A = "[A]",
  D = "[D]",
  R = "[R]",
  C = "[C]",
  U = "[U]",
}

-- Line -> action map (rebuilt each render)
local line_actions = {}

-- Render the explorer buffer
function M.render()
  local s = state.get()
  local buf = s.buffers.explorer
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local lines = {}
  line_actions = {}

  -- Header
  table.insert(lines, " codereview")
  table.insert(lines, " ─────────────────────────")
  line_actions[1] = nil
  line_actions[2] = nil

  -- File list
  for idx, file in ipairs(s.files) do
    local icon = STATUS_ICONS[file.status] or "[?]"
    local marker = (idx == s.current_file_idx) and "▶ " or "  "
    local note_count = store.count_for_file(file.path)
    local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""
    local line = marker .. icon .. " " .. file.path .. note_marker
    table.insert(lines, line)
    line_actions[#lines] = { type = "file", idx = idx }

    -- Show notes as sub-items if expanded
    if file.expanded then
      local notes = store.get_for_file(file.path)
      for _, note in ipairs(notes) do
        local short = note.text:gsub("\n", " ")
        local note_line = "    ⊳ L" .. note.line_start .. ": " ..
          (short:sub(1, 30) .. (#short > 30 and "…" or ""))
        table.insert(lines, note_line)
        line_actions[#lines] = { type = "note", filepath = file.path, line = note.line_start }
      end
    end
  end

  -- Footer hint
  table.insert(lines, "")
  table.insert(lines, " [q]uit  [R]efresh  <C-s>save")

  -- Write to buffer
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply highlights
  M._apply_highlights(buf, lines)
end

function M._apply_highlights(buf, lines)
  local ns = vim.api.nvim_create_namespace("codereview_explorer")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for lnum, _ in ipairs(lines) do
    local action = line_actions[lnum]
    if action then
      if action.type == "file" then
        local s = state.get()
        local hl = "Normal"
        if s.files[action.idx] then
          local status = s.files[action.idx].status
          if status == "A" then hl = "DiffAdd"
          elseif status == "D" then hl = "DiffDelete"
          elseif status == "M" then hl = "DiffChange"
          end
        end
        vim.api.nvim_buf_add_highlight(buf, ns, hl, lnum - 1, 0, -1)
      elseif action.type == "note" then
        vim.api.nvim_buf_add_highlight(buf, ns, "Comment", lnum - 1, 0, -1)
      end
    end
  end

  -- Header highlights
  vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 0, -1)
end

-- Get the action for the current cursor line
function M.get_current_action()
  local s = state.get()
  local win = s.windows.explorer
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  return line_actions[lnum]
end

-- Set the selected file by index
function M.select_file(idx)
  local s = state.get()
  if idx < 1 or idx > #s.files then return end
  s.current_file_idx = idx
  M.render()
  M._move_cursor_to_file(idx)
end

function M._move_cursor_to_file(idx)
  local s = state.get()
  local win = s.windows.explorer
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  for lnum, action in pairs(line_actions) do
    if action and action.type == "file" and action.idx == idx then
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      return
    end
  end
end

-- Setup keymaps for the explorer buffer
function M.setup_keymaps(buf)
  local cfg = config.options
  local km = cfg.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  local function open_current()
    local action = M.get_current_action()
    if not action then return end
    if action.type == "file" then
      M.select_file(action.idx)
      require("codereview.ui.diff_view").show_file(action.idx)
      require("codereview.ui.layout").focus_diff()
    elseif action.type == "note" then
      local s = state.get()
      for fi, f in ipairs(s.files) do
        if f.path == action.filepath then
          M.select_file(fi)
          require("codereview.ui.diff_view").show_file(fi)
          require("codereview.ui.diff_view").jump_to_line(action.line)
          require("codereview.ui.layout").focus_diff()
          break
        end
      end
    end
  end

  vim.keymap.set("n", "<CR>", open_current, opts)
  vim.keymap.set("n", "l", open_current, opts)

  -- Toggle notes expand/collapse
  vim.keymap.set("n", km.toggle_notes, function()
    local action = M.get_current_action()
    if action and action.type == "file" then
      local s = state.get()
      local file = s.files[action.idx]
      if file then
        file.expanded = not file.expanded
        M.render()
      end
    end
  end, opts)

  -- Next/prev file
  vim.keymap.set("n", km.next_file, function()
    local s = state.get()
    if s.current_file_idx < #s.files then
      M.select_file(s.current_file_idx + 1)
      require("codereview.ui.diff_view").show_file(s.current_file_idx)
    end
  end, opts)

  vim.keymap.set("n", km.prev_file, function()
    local s = state.get()
    if s.current_file_idx > 1 then
      M.select_file(s.current_file_idx - 1)
      require("codereview.ui.diff_view").show_file(s.current_file_idx)
    end
  end, opts)

  -- Refresh
  vim.keymap.set("n", km.refresh, function()
    require("codereview").refresh()
  end, opts)

  -- Quit
  vim.keymap.set("n", km.quit, function()
    require("codereview.ui.layout").safe_close(false)
  end, opts)

  -- Tab: cycle focus to diff panel
  vim.keymap.set("n", "<Tab>", function()
    require("codereview.ui.layout").focus_diff()
  end, opts)

  -- Save
  vim.keymap.set("n", km.save, function()
    require("codereview.review.exporter").save_with_prompt()
  end, opts)

  local layout = require("codereview.ui.layout")
  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
end

return M
