local safe = require("codereview.util.safe")

describe("util.safe", function()

  -- pcall()

  it("returns true when the wrapped function succeeds", function()
    local ok, _ = safe.pcall(function() end)
    assert.is_true(ok)
  end)

  it("returns the function's return value on success", function()
    local ok, val = safe.pcall(function() return 42 end)
    assert.is_true(ok)
    assert.equals(42, val)
  end)

  it("returns false when the wrapped function errors", function()
    local ok, _ = safe.pcall(function() error("boom") end)
    assert.is_false(ok)
  end)

  it("returns the error message on failure", function()
    local ok, err = safe.pcall(function() error("something went wrong") end)
    assert.is_false(ok)
    assert.truthy(tostring(err):find("something went wrong", 1, true))
  end)

  it("passes arguments through to the wrapped function", function()
    local got_a, got_b
    safe.pcall(function(a, b)
      got_a = a
      got_b = b
    end, "hello", 99)
    assert.equals("hello", got_a)
    assert.equals(99, got_b)
  end)

  it("does not re-raise the error", function()
    -- If safe.pcall re-raised, this test itself would error.
    assert.has_no.errors(function()
      safe.pcall(function() error("should be caught") end)
    end)
  end)

  it("schedules a vim.notify call on failure", function()
    local scheduled = false
    local orig_schedule = vim.schedule
    vim.schedule = function(fn)
      scheduled = true
      -- Execute synchronously so we can observe the notify call in tests.
      fn()
    end

    local notified = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.DEBUG then
        notified = true
      end
    end

    safe.pcall(function() error("test error") end)

    vim.schedule = orig_schedule
    vim.notify   = orig_notify

    assert.is_true(scheduled)
    assert.is_true(notified)
  end)

  it("notify message contains the error text", function()
    local notify_msg = nil
    local orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    local orig_notify = vim.notify
    vim.notify = function(msg, _) notify_msg = msg end

    safe.pcall(function() error("unique_error_xyz") end)

    vim.schedule = orig_schedule
    vim.notify   = orig_notify

    assert.truthy(notify_msg and notify_msg:find("unique_error_xyz", 1, true))
  end)
end)
