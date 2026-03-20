local config = require("codereview.config")

describe("config", function()
  before_each(function()
    config.options = {}
  end)

  it("has expected defaults", function()
    assert.equals("unified", config.defaults.diff_view)
    assert.equals(30, config.defaults.explorer_width)
    assert.equals(30, config.defaults.note_truncate_len)
    assert.equals(60, config.defaults.virtual_text_truncate_len)
    assert.equals(1200, config.defaults.max_diff_lines)
    assert.equals(400, config.defaults.diff_page_size)
    assert.is_true(config.defaults.show_untracked)
  end)

  it("setup({}) produces defaults", function()
    config.setup({})
    assert.equals("unified", config.options.diff_view)
    assert.equals(30, config.options.explorer_width)
  end)

  it("setup(nil) produces defaults", function()
    config.setup(nil)
    assert.equals("unified", config.options.diff_view)
  end)

  it("deep-merges overrides", function()
    config.setup({ diff_view = "split", explorer_width = 40 })
    assert.equals("split", config.options.diff_view)
    assert.equals(40, config.options.explorer_width)
    -- non-overridden key stays at default
    assert.equals(1200, config.options.max_diff_lines)
  end)

  it("deep-merges nested keymaps", function()
    config.setup({ keymaps = { note = "N" } })
    assert.equals("N", config.options.keymaps.note)
    -- other keymaps untouched
    assert.equals("q", config.options.keymaps.quit)
  end)

  it("allows false to disable a keymap", function()
    config.setup({ keymaps = { save = false } })
    assert.equals(false, config.options.keymaps.save)
  end)

  it("rejects invalid diff_view value", function()
    -- prime options with a valid config first, then install the spy
    config.setup({})
    local opts_before = vim.deepcopy(config.options)
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ diff_view = "bad_value" })
    vim.notify = orig
    assert.is_true(notified)
    -- options must not be updated after a failed setup
    assert.equals(opts_before.diff_view, config.options.diff_view)
  end)

  it("rejects non-positive explorer_width", function()
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ explorer_width = -5 })
    vim.notify = orig
    assert.is_true(notified)
  end)

  it("rejects unknown keymap key", function()
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ keymaps = { tpyo_key = "x" } })
    vim.notify = orig
    assert.is_true(notified)
  end)

  it("rejects keymap value that is not a string or false", function()
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ keymaps = { note = 123 } })
    vim.notify = orig
    assert.is_true(notified)
  end)

  it("rejects negative review.context_lines", function()
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ review = { context_lines = -1 } })
    vim.notify = orig
    assert.is_true(notified)
  end)

  it("accepts valid review sub-table", function()
    config.setup({ review = { context_lines = 3, path = "/tmp" } })
    assert.equals(3, config.options.review.context_lines)
    assert.equals("/tmp", config.options.review.path)
  end)

  it("default export_format is 'inline'", function()
    config.setup({})
    assert.equals("inline", config.options.review.export_format)
  end)

  it("accepts valid export_format values", function()
    for _, fmt in ipairs({ "inline", "compact", "block" }) do
      config.setup({ review = { export_format = fmt } })
      assert.equals(fmt, config.options.review.export_format)
    end
  end)

  it("rejects invalid export_format value", function()
    local notified = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified = true end
    end
    config.setup({ review = { export_format = "bad_format" } })
    vim.notify = orig
    assert.is_true(notified)
  end)
end)
