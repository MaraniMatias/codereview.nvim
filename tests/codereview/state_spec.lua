local state = require("codereview.state")

describe("state", function()
  before_each(function()
    state.reset()
  end)

  it("init() produces empty files and nil mode", function()
    state.init()
    local s = state.get()
    assert.equals(nil, s.mode)
    assert.same({}, s.files)
    assert.equals(1, s.current_file_idx)
  end)

  it("get() returns a mutable reference", function()
    state.init()
    local s = state.get()
    s.mode = "review"
    assert.equals("review", state.get().mode)
  end)

  it("reset() restores nil mode", function()
    state.init()
    local s = state.get()
    s.mode = "difftool"
    state.reset()
    assert.equals(nil, state.get().mode)
  end)

  it("reset() clears files", function()
    state.init()
    local s = state.get()
    s.files = { { path = "foo.lua", status = "M" } }
    state.reset()
    assert.same({}, state.get().files)
  end)

  it("init() is independent between calls", function()
    state.init()
    state.get().mode = "review"
    state.init()
    assert.equals(nil, state.get().mode)
  end)
end)
