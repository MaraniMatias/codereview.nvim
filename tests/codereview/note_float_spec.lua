-- Tests for codereview.ui.note_float
-- Covers: N01 fix — BufLeave asks save/discard, closing guard prevents re-entry

-- ──────────────────────────────────────────────────────────────
-- Stub infrastructure
-- ──────────────────────────────────────────────────────────────

-- Track calls made during tests
local call_log = {}

local function reset_log()
  call_log = {}
end

local function log_call(name, ...)
  table.insert(call_log, { name = name, args = { ... } })
end

local function find_calls(name)
  local found = {}
  for _, c in ipairs(call_log) do
    if c.name == name then table.insert(found, c) end
  end
  return found
end

-- ──────────────────────────────────────────────────────────────
-- Before loading the module, set up minimal vim stubs that
-- note_float.lua needs at require-time (store dependency).
-- ──────────────────────────────────────────────────────────────

local store_stub = {
  set = function(...) log_call("store.set", ...) end,
}
package.loaded["codereview.notes.store"] = store_stub

local state_stub = {
  get = function()
    return { files = {}, buffers = {} }
  end,
}
package.loaded["codereview.state"] = state_stub

local diff_view_stub = {
  refresh_notes = function() log_call("diff_view.refresh_notes") end,
}
package.loaded["codereview.ui.diff_view"] = diff_view_stub

local explorer_stub = {
  render = function() log_call("explorer.render") end,
}
package.loaded["codereview.ui.explorer"] = explorer_stub

-- Now require the module under test
local note_float = require("codereview.ui.note_float")

-- ──────────────────────────────────────────────────────────────
-- Helpers to drive note_float internals via the public API
-- ──────────────────────────────────────────────────────────────

-- Collect autocmds and keymaps registered during open()
local registered_autocmds = {}
local registered_keymaps = {}
local buf_lines = {}
local valid_wins = {}
local closed_wins = {}
local confirm_answer = 1 -- 1=Yes, 2=No, 3=Cancel
local scheduled_fns = {}

-- Override vim APIs used by note_float.open / close / confirm
local orig_create_buf = vim.api.nvim_create_buf
local orig_set_option = vim.api.nvim_set_option_value
local orig_open_win = vim.api.nvim_open_win
local orig_create_autocmd = vim.api.nvim_create_autocmd
local orig_buf_set_lines = vim.api.nvim_buf_set_lines
local orig_buf_get_lines = vim.api.nvim_buf_get_lines
local orig_win_is_valid = vim.api.nvim_win_is_valid
local orig_win_close = vim.api.nvim_win_close
local orig_win_set_cursor = vim.api.nvim_win_set_cursor
local orig_list_uis = vim.api.nvim_list_uis
local orig_keymap_set = vim.keymap.set
local orig_cmd = vim.cmd
local orig_confirm = vim.fn.confirm
local orig_notify = vim.notify
local orig_schedule = vim.schedule

local next_buf_id = 100
local next_win_id = 200

local function setup_vim_stubs()
  next_buf_id = 100
  next_win_id = 200
  registered_autocmds = {}
  registered_keymaps = {}
  buf_lines = {}
  valid_wins = {}
  closed_wins = {}
  scheduled_fns = {}
  confirm_answer = 1

  vim.api.nvim_create_buf = function()
    next_buf_id = next_buf_id + 1
    return next_buf_id
  end

  vim.api.nvim_set_option_value = function() end

  vim.api.nvim_open_win = function(buf, enter, opts)
    next_win_id = next_win_id + 1
    valid_wins[next_win_id] = true
    return next_win_id
  end

  vim.api.nvim_create_autocmd = function(event, opts)
    table.insert(registered_autocmds, { event = event, opts = opts })
    return #registered_autocmds
  end

  vim.api.nvim_buf_set_lines = function(buf, start, stop, strict, lines)
    buf_lines[buf] = lines
  end

  vim.api.nvim_buf_get_lines = function(buf)
    return buf_lines[buf] or { "" }
  end

  vim.api.nvim_win_is_valid = function(win)
    return valid_wins[win] == true
  end

  vim.api.nvim_win_close = function(win, force)
    log_call("win_close", win)
    valid_wins[win] = nil
    table.insert(closed_wins, win)
  end

  vim.api.nvim_win_set_cursor = function() end

  vim.api.nvim_list_uis = function()
    return { { width = 120, height = 40 } }
  end

  vim.api.nvim_buf_add_highlight = function() end

  vim.keymap.set = function(mode, key, fn, opts)
    table.insert(registered_keymaps, { mode = mode, key = key, fn = fn })
  end

  vim.cmd = function() end

  vim.fn.confirm = function(msg, choices, default)
    log_call("confirm", msg, choices)
    return confirm_answer
  end

  vim.notify = function(msg, level)
    log_call("notify", msg, level)
  end

  vim.schedule = function(fn)
    table.insert(scheduled_fns, fn)
  end
end

local function restore_vim_stubs()
  vim.api.nvim_create_buf = orig_create_buf
  vim.api.nvim_set_option_value = orig_set_option
  vim.api.nvim_open_win = orig_open_win
  vim.api.nvim_create_autocmd = orig_create_autocmd
  vim.api.nvim_buf_set_lines = orig_buf_set_lines
  vim.api.nvim_buf_get_lines = orig_buf_get_lines
  vim.api.nvim_win_is_valid = orig_win_is_valid
  vim.api.nvim_win_close = orig_win_close
  vim.api.nvim_win_set_cursor = orig_win_set_cursor
  vim.api.nvim_list_uis = orig_list_uis
  vim.keymap.set = orig_keymap_set
  vim.cmd = orig_cmd
  vim.fn.confirm = orig_confirm
  vim.notify = orig_notify
  vim.schedule = orig_schedule
end

--- Open a note and set buffer content for the note buffer
local function open_note_with_text(text)
  note_float.open("test.lua", 10, 12, "local x = 1", nil, "new")
  -- Find the note buffer (second buf created)
  local note_buf = next_buf_id
  buf_lines[note_buf] = vim.split(text, "\n")
end

--- Find and fire a registered BufLeave autocmd
local function fire_buf_leave()
  for _, ac in ipairs(registered_autocmds) do
    if ac.event == "BufLeave" then
      ac.opts.callback()
      return true
    end
  end
  return false
end

--- Run all scheduled functions
local function run_scheduled()
  local fns = scheduled_fns
  scheduled_fns = {}
  for _, fn in ipairs(fns) do
    fn()
  end
end

-- ──────────────────────────────────────────────────────────────
-- Tests
-- ──────────────────────────────────────────────────────────────

describe("note_float – N01 BufLeave behavior", function()
  before_each(function()
    reset_log()
    setup_vim_stubs()
    -- Ensure module is in clean state
    if note_float.is_open() then
      note_float.close()
    end
    reset_log()
  end)

  after_each(function()
    -- Force cleanup
    pcall(note_float.close)
    restore_vim_stubs()
  end)

  it("BufLeave schedules ask_save_or_discard instead of close", function()
    open_note_with_text("some note text")

    -- Fire BufLeave
    fire_buf_leave()

    -- Should have scheduled a function, not called close directly
    assert.equals(1, #scheduled_fns, "should schedule exactly one function")
    assert.equals(0, #find_calls("win_close"), "should NOT close windows yet")
  end)

  it("BufLeave + Yes saves the note", function()
    open_note_with_text("important note")
    confirm_answer = 1 -- Yes

    fire_buf_leave()
    run_scheduled()

    local saves = find_calls("store.set")
    assert.equals(1, #saves, "should save note via store.set")
    assert.equals("test.lua", saves[1].args[1])
  end)

  it("BufLeave + No discards without saving", function()
    open_note_with_text("draft note")
    confirm_answer = 2 -- No

    fire_buf_leave()
    run_scheduled()

    assert.equals(0, #find_calls("store.set"), "should NOT save")
    assert.equals(false, note_float.is_open(), "float should be closed")
  end)

  it("BufLeave + Cancel keeps the float open", function()
    open_note_with_text("wip note")
    confirm_answer = 3 -- Cancel

    fire_buf_leave()
    run_scheduled()

    assert.equals(0, #find_calls("store.set"), "should NOT save")
    assert.equals(true, note_float.is_open(), "float should remain open")
  end)

  it("BufLeave with empty text closes silently", function()
    open_note_with_text("")

    fire_buf_leave()
    run_scheduled()

    assert.equals(0, #find_calls("confirm"), "should NOT prompt for empty note")
    assert.equals(false, note_float.is_open(), "float should be closed")
  end)
end)

describe("note_float – closing guard", function()
  before_each(function()
    reset_log()
    setup_vim_stubs()
    if note_float.is_open() then
      note_float.close()
    end
    reset_log()
  end)

  after_each(function()
    pcall(note_float.close)
    restore_vim_stubs()
  end)

  it("close() is idempotent — second call is a no-op", function()
    open_note_with_text("test")

    note_float.close()
    local first_closes = #find_calls("win_close")

    note_float.close()
    local second_closes = #find_calls("win_close")

    assert.is_true(first_closes > 0, "first close should close windows")
    assert.equals(first_closes, second_closes, "second close should be a no-op")
  end)

  it("confirm() with empty text still closes properly", function()
    open_note_with_text("")

    note_float.confirm()

    assert.equals(false, note_float.is_open(), "float should be closed")
    assert.equals(0, #find_calls("store.set"), "should NOT save empty note")
  end)

  it("BufLeave during close() does not trigger ask_save_or_discard", function()
    open_note_with_text("some text")

    -- Simulate: close() is running, BufLeave fires mid-close
    -- We do this by monkey-patching win_close to fire BufLeave
    local orig_stub_close = vim.api.nvim_win_close
    vim.api.nvim_win_close = function(win, force)
      orig_stub_close(win, force)
      -- Simulate BufLeave firing during window close
      fire_buf_leave()
    end

    note_float.close()

    -- The BufLeave callback should not have scheduled anything
    -- because closing = true during close()
    assert.equals(0, #scheduled_fns, "should NOT schedule ask during close")

    vim.api.nvim_win_close = orig_stub_close
  end)
end)

describe("note_float – N02 keymap registration", function()
  before_each(function()
    reset_log()
    setup_vim_stubs()
    if note_float.is_open() then
      note_float.close()
    end
    reset_log()
    registered_keymaps = {}
  end)

  after_each(function()
    pcall(note_float.close)
    restore_vim_stubs()
  end)

  it("does NOT register 'w' as a normal-mode keymap", function()
    open_note_with_text("test")
    for _, km in ipairs(registered_keymaps) do
      if km.key == "w" then
        -- If mode is "n" or includes "n", that's the old bug
        local modes = type(km.mode) == "table" and km.mode or { km.mode }
        for _, m in ipairs(modes) do
          assert.not_equals("n", m, "'w' should NOT be mapped in normal mode")
        end
      end
    end
  end)

  it("registers <C-s> as save keymap", function()
    open_note_with_text("test")
    local found = false
    for _, km in ipairs(registered_keymaps) do
      if km.key == "<C-s>" then
        found = true
        break
      end
    end
    assert.is_true(found, "<C-s> keymap should be registered")
  end)

  it("registers BufWriteCmd autocmd for :w support", function()
    open_note_with_text("test")
    local found = false
    for _, ac in ipairs(registered_autocmds) do
      if ac.event == "BufWriteCmd" then
        found = true
        break
      end
    end
    assert.is_true(found, "BufWriteCmd autocmd should be registered")
  end)
end)
