-- Tests for codereview.ui.explorer.view – move_cursor_to_file
-- Verifies that the cursor lands on the file row, not a note row, and that
-- ascending line iteration is used (regression for the pairs() bug).

local state          = require("codereview.state")
local explorer_state = require("codereview.ui.explorer.state")
local view           = require("codereview.ui.explorer.view")

-- Helper: create a scratch buffer, fill it with N lines, open a floating
-- window pointing at it, and return { buf, win }.
local function make_buf_win(line_count)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, line_count do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0, col = 0,
    width = 40, height = line_count,
    style = "minimal",
    focusable = false,
  })
  return buf, win
end

describe("explorer view – move_cursor_to_file", function()
  local buf, win

  before_each(function()
    state.reset()
  end)

  after_each(function()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    state.reset()
  end)

  it("moves cursor to the correct file row", function()
    -- Layout: header(1) | file1(2) | file2(3)
    buf, win = make_buf_win(3)
    local s = state.get()
    s.windows.explorer = win
    s.buffers.explorer = buf
    s.files = {
      { path = "a.lua", status = "M" },
      { path = "b.lua", status = "A" },
    }

    explorer_state.set_actions_by_line({
      [2] = { type = "file", idx = 1 },
      [3] = { type = "file", idx = 2 },
    })

    view.move_cursor_to_file(2)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    assert.equals(3, row)
  end)

  it("lands on file row even when note rows appear before it in the table", function()
    -- Layout: header(1) | file1(2) | note1(3) | note2(4) | file2(5)
    -- With pairs() the note rows for file2's idx would never be there, but
    -- we simulate the case where the file row comes AFTER note rows in memory.
    buf, win = make_buf_win(5)
    local s = state.get()
    s.windows.explorer = win
    s.buffers.explorer = buf

    -- Build actions_by_line so that file2's action is at line 5,
    -- and notes (which carry their parent's filepath, not idx) are at 3 and 4.
    explorer_state.set_actions_by_line({
      [2] = { type = "file",  idx = 1 },
      [3] = { type = "note",  filepath = "a.lua", line = 1, side = "new" },
      [4] = { type = "note",  filepath = "a.lua", line = 2, side = "new" },
      [5] = { type = "file",  idx = 2 },
    })

    view.move_cursor_to_file(2)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    -- Must be line 5 (the file row), not any earlier line
    assert.equals(5, row)
  end)

  it("does nothing when the window is invalid", function()
    -- Should not error; just silently return
    local s = state.get()
    s.windows.explorer = 99999  -- bogus handle
    s.buffers.explorer = 99999

    explorer_state.set_actions_by_line({
      [2] = { type = "file", idx = 1 },
    })

    assert.has_no_error(function()
      view.move_cursor_to_file(1)
    end)
  end)

  it("does nothing when idx is not found in actions_by_line", function()
    buf, win = make_buf_win(2)
    local s = state.get()
    s.windows.explorer = win
    s.buffers.explorer = buf

    explorer_state.set_actions_by_line({
      [2] = { type = "file", idx = 1 },
    })

    -- Move cursor to a known position first
    vim.api.nvim_win_set_cursor(win, { 2, 0 })

    -- idx=99 doesn't exist → cursor must stay where it is
    view.move_cursor_to_file(99)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    assert.equals(2, row)
  end)
end)
