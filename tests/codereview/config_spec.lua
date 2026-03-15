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
end)
