local events = require("codereview.events")

describe("events", function()
  before_each(function()
    events.clear()
  end)

  -- on() / emit()

  it("calls a registered handler when event is emitted", function()
    local called = false
    events.on("test", function() called = true end)
    events.emit("test")
    assert.is_true(called)
  end)

  it("passes arguments to the handler", function()
    local received = {}
    events.on("data", function(a, b) received = { a, b } end)
    events.emit("data", 42, "hello")
    assert.equals(42, received[1])
    assert.equals("hello", received[2])
  end)

  it("calls multiple handlers registered for the same event", function()
    local count = 0
    events.on("multi", function() count = count + 1 end)
    events.on("multi", function() count = count + 1 end)
    events.emit("multi")
    assert.equals(2, count)
  end)

  it("calls handlers in registration order", function()
    local order = {}
    events.on("order", function() table.insert(order, 1) end)
    events.on("order", function() table.insert(order, 2) end)
    events.on("order", function() table.insert(order, 3) end)
    events.emit("order")
    assert.same({ 1, 2, 3 }, order)
  end)

  it("does not call handlers of other events", function()
    local called = false
    events.on("event_a", function() called = true end)
    events.emit("event_b")
    assert.is_false(called)
  end)

  it("emit on an event with no handlers does not error", function()
    assert.has_no.errors(function()
      events.emit("unknown_event")
    end)
  end)

  it("allows multiple emissions of the same event", function()
    local count = 0
    events.on("repeat", function() count = count + 1 end)
    events.emit("repeat")
    events.emit("repeat")
    events.emit("repeat")
    assert.equals(3, count)
  end)

  -- clear()

  it("clear() removes all handlers", function()
    local called = false
    events.on("evt", function() called = true end)
    events.clear()
    events.emit("evt")
    assert.is_false(called)
  end)

  it("clear() affects all events", function()
    local a, b = false, false
    events.on("e1", function() a = true end)
    events.on("e2", function() b = true end)
    events.clear()
    events.emit("e1")
    events.emit("e2")
    assert.is_false(a)
    assert.is_false(b)
  end)

  it("can register new handlers after clear()", function()
    events.on("evt", function() end)
    events.clear()
    local called = false
    events.on("evt", function() called = true end)
    events.emit("evt")
    assert.is_true(called)
  end)
end)
