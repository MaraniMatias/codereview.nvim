local valid = require("codereview.util.validate")

describe("util.validate", function()

  -- buf()

  describe("buf()", function()
    it("returns false for nil", function()
      assert.is_false(valid.buf(nil))
    end)

    it("returns false for an invalid buffer handle", function()
      -- nvim_buf_is_valid expects an integer; use an out-of-range handle
      assert.is_false(valid.buf(999999))
    end)

    it("returns true for a valid scratch buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      assert.is_true(valid.buf(buf))
      -- cleanup
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns false after the buffer is deleted", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_false(valid.buf(buf))
    end)
  end)

  -- win()

  describe("win()", function()
    it("returns false for nil", function()
      assert.is_false(valid.win(nil))
    end)

    it("returns true for the current window", function()
      local win = vim.api.nvim_get_current_win()
      assert.is_true(valid.win(win))
    end)

    it("returns false for an invalid window handle", function()
      -- 999999 is very unlikely to be a valid window
      assert.is_false(valid.win(999999))
    end)
  end)

  -- tab()

  describe("tab()", function()
    it("returns false for nil", function()
      assert.is_false(valid.tab(nil))
    end)

    it("returns true for the current tabpage", function()
      local tab = vim.api.nvim_get_current_tabpage()
      assert.is_true(valid.tab(tab))
    end)

    it("returns false for an invalid tabpage handle", function()
      assert.is_false(valid.tab(999999))
    end)
  end)

  -- win_in_tab()

  describe("win_in_tab()", function()
    it("returns false when win is nil", function()
      local tab = vim.api.nvim_get_current_tabpage()
      assert.is_false(valid.win_in_tab(nil, tab))
    end)

    it("returns false when tab is nil", function()
      local win = vim.api.nvim_get_current_win()
      assert.is_false(valid.win_in_tab(win, nil))
    end)

    it("returns true when win belongs to tab", function()
      local win = vim.api.nvim_get_current_win()
      local tab = vim.api.nvim_get_current_tabpage()
      assert.is_true(valid.win_in_tab(win, tab))
    end)

    it("returns false for invalid win with valid tab", function()
      local tab = vim.api.nvim_get_current_tabpage()
      assert.is_false(valid.win_in_tab(999999, tab))
    end)
  end)
end)
