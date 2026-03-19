local buf_util = require("codereview.util.buf")

-- Helper: read buffer lines
local function get_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Helper: get a buffer option
local function buf_opt(buf, name)
  return vim.api.nvim_get_option_value(name, { buf = buf })
end

describe("util.buf", function()

  -- create()

  describe("create()", function()
    local buf

    after_each(function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("returns a valid buffer handle", function()
      buf = buf_util.create("test://create_basic")
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
    end)

    it("sets the buffer name", function()
      buf = buf_util.create("test://my_buf_name")
      assert.equals("test://my_buf_name", vim.api.nvim_buf_get_name(buf))
    end)

    it("is not listed (unlisted scratch buffer)", function()
      buf = buf_util.create("test://unlisted")
      assert.is_false(vim.api.nvim_get_option_value("buflisted", { buf = buf }))
    end)

    it("has buftype 'acwrite' by default", function()
      buf = buf_util.create("test://buftype")
      assert.equals("acwrite", buf_opt(buf, "buftype"))
    end)

    it("has swapfile disabled by default", function()
      buf = buf_util.create("test://swapfile")
      assert.is_false(buf_opt(buf, "swapfile"))
    end)

    it("is not modifiable by default", function()
      buf = buf_util.create("test://not_modifiable")
      assert.is_false(buf_opt(buf, "modifiable"))
    end)

    it("bufhidden is 'wipe' by default", function()
      buf = buf_util.create("test://bufhidden")
      assert.equals("wipe", buf_opt(buf, "bufhidden"))
    end)

    it("accepts option overrides", function()
      buf = buf_util.create("test://override", { buftype = "nofile" })
      assert.equals("nofile", buf_opt(buf, "buftype"))
    end)
  end)

  -- set_options()

  describe("set_options()", function()
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("sets multiple options at once", function()
      buf_util.set_options(buf, { swapfile = false, bufhidden = "wipe" })
      assert.is_false(buf_opt(buf, "swapfile"))
      assert.equals("wipe", buf_opt(buf, "bufhidden"))
    end)
  end)

  -- set_lines()

  describe("set_lines()", function()
    local buf

    before_each(function()
      -- create a writable scratch buffer for each test
      buf = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("sets buffer content to the given lines", function()
      buf_util.set_lines(buf, { "hello", "world" })
      assert.same({ "hello", "world" }, get_lines(buf))
    end)

    it("replaces existing content", function()
      buf_util.set_lines(buf, { "old" })
      buf_util.set_lines(buf, { "new1", "new2" })
      assert.same({ "new1", "new2" }, get_lines(buf))
    end)

    it("leaves buffer non-modifiable after setting lines", function()
      -- make buffer modifiable first so set_lines can write
      vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
      buf_util.set_lines(buf, { "line" })
      -- set_lines should restore non-modifiable state
      assert.is_false(buf_opt(buf, "modifiable"))
    end)

    it("clears the modified flag after setting lines", function()
      vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
      buf_util.set_lines(buf, { "content" })
      assert.is_false(buf_opt(buf, "modified"))
    end)

    it("accepts an empty lines table", function()
      buf_util.set_lines(buf, { "some content" })
      buf_util.set_lines(buf, {})
      assert.same({ "" }, get_lines(buf))
    end)
  end)
end)
