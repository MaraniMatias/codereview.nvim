-- Tests for codereview.git
-- Strategy: mock M._run to avoid spawning real processes.
-- This lets us test the parsing and classification logic in isolation.

local git = require("codereview.git")

-- Replace M._run with a stub that calls back synchronously.
local function stub_run(stdout, exit_code, stderr)
  git._run = function(_, callback)
    callback(stdout, exit_code, stderr or "")
  end
end

-- Restore _run to a no-op so stale stubs don't leak between tests.
local function restore_run()
  git._run = function(_, callback)
    callback("", 0, "")
  end
end

describe("git – get_repo_root()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("calls back with the trimmed root path on success", function()
    stub_run("/home/user/project\n", 0)
    local result
    git.get_repo_root(nil, function(r) result = r end)
    assert.equals("/home/user/project", result)
  end)

  it("calls back with nil when exit_code is non-zero", function()
    stub_run("", 128, "not a git repository")
    local result = "sentinel"
    git.get_repo_root(nil, function(r) result = r end)
    assert.is_nil(result)
  end)

  it("calls back with nil when stdout is empty", function()
    stub_run("", 0, "")
    local result = "sentinel"
    git.get_repo_root(nil, function(r) result = r end)
    assert.is_nil(result)
  end)
end)

describe("git – get_changed_files()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("parses M/A/D status lines", function()
    stub_run("M\tsrc/foo.lua\nA\tsrc/bar.lua\nD\tsrc/baz.lua\n", 0)
    local files
    git.get_changed_files("/root", {}, function(f) files = f end)
    assert.equals(3, #files)
    assert.equals("M", files[1].status)
    assert.equals("src/foo.lua", files[1].path)
    assert.equals("A", files[2].status)
    assert.equals("D", files[3].status)
  end)

  it("parses rename lines (R100 format)", function()
    stub_run("R100\told/path.lua\tnew/path.lua\n", 0)
    local files
    git.get_changed_files("/root", {}, function(f) files = f end)
    assert.equals(1, #files)
    assert.equals("R", files[1].status)
    assert.equals("new/path.lua", files[1].path)
    assert.equals("old/path.lua", files[1].old_path)
  end)

  it("returns empty list when output is empty", function()
    stub_run("", 0)
    local files
    git.get_changed_files("/root", {}, function(f) files = f end)
    assert.same({}, files)
  end)

  it("calls back with nil and notifies on error", function()
    stub_run("", 128, "fatal: not a git repository")
    local notified = false
    local orig_notify = vim.notify
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then notified = true end
    end

    local result = "sentinel"
    git.get_changed_files("/root", {}, function(f) result = f end)

    vim.notify = orig_notify
    assert.is_nil(result)
    assert.is_true(notified)
  end)
end)

describe("git – get_binary_files()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("identifies binary files from numstat output", function()
    stub_run("-\t-\tsrc/image.png\n1\t2\tsrc/text.lua\n", 0)
    local binaries
    git.get_binary_files("/root", {}, function(b) binaries = b end)
    assert.is_true(binaries["src/image.png"])
    assert.is_nil(binaries["src/text.lua"])
  end)

  it("returns empty table on command error", function()
    stub_run("", 128, "error")
    local binaries
    git.get_binary_files("/root", {}, function(b) binaries = b end)
    assert.same({}, binaries)
  end)

  it("returns empty table when no binary files present", function()
    stub_run("5\t3\tsrc/foo.lua\n2\t0\tsrc/bar.lua\n", 0)
    local binaries
    git.get_binary_files("/root", {}, function(b) binaries = b end)
    assert.same({}, binaries)
  end)
end)

describe("git – get_file_diff()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("returns diff content on success", function()
    local diff = "diff --git a/f b/f\n@@ -1 +1 @@\n-old\n+new\n"
    stub_run(diff, 0)
    local result
    git.get_file_diff("/root", { path = "f.lua", status = "M" }, {}, function(d) result = d end)
    assert.equals(diff, result)
  end)

  it("calls back with nil and warns on error", function()
    stub_run("", 1, "fatal: not a git repository")
    local notified = false
    local orig_notify = vim.notify
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then notified = true end
    end

    local result = "sentinel"
    git.get_file_diff("/root", { path = "f.lua", status = "M" }, {}, function(d) result = d end)

    vim.notify = orig_notify
    assert.is_nil(result)
    assert.is_true(notified)
  end)

  it("builds rename diff argv with old_path and new_path", function()
    local captured_argv
    git._run = function(argv, callback)
      captured_argv = argv
      callback("", 0, "")
    end

    git.get_file_diff("/root", { path = "new.lua", old_path = "old.lua", status = "R" }, {}, function() end)

    -- argv should include both old_path and new_path after "--"
    local dash_dash_idx
    for i, v in ipairs(captured_argv) do
      if v == "--" then dash_dash_idx = i; break end
    end
    assert.is_not_nil(dash_dash_idx)
    assert.equals("old.lua", captured_argv[dash_dash_idx + 1])
    assert.equals("new.lua", captured_argv[dash_dash_idx + 2])
  end)

  it("returns binary placeholder when output contains 'Binary files'", function()
    stub_run("Binary files a/img.png and b/img.png differ\n", 0)
    local result
    git.get_file_diff("/root", { path = "img.png", status = "M" }, {}, function(d) result = d end)
    assert.truthy(result and result:find("Binary", 1, true))
  end)
end)

describe("git – get_staged_diff()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("returns staged diff content on success", function()
    local diff = "@@ -1 +1 @@\n-a\n+b\n"
    stub_run(diff, 0)
    local result
    git.get_staged_diff("/root", "file.lua", function(d) result = d end)
    assert.equals(diff, result)
  end)

  it("calls back with nil on error", function()
    stub_run("", 1, "fatal: not a git repository")
    local result = "sentinel"
    git.get_staged_diff("/root", "file.lua", function(d) result = d end)
    assert.is_nil(result)
  end)
end)

describe("git – get_untracked_files()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("parses untracked file paths", function()
    stub_run("new_file.lua\nsrc/other.lua\n", 0)
    local files
    git.get_untracked_files("/root", function(f) files = f end)
    assert.equals(2, #files)
    assert.equals("?", files[1].status)
    assert.equals("new_file.lua", files[1].path)
    assert.equals("?", files[2].status)
    assert.equals("src/other.lua", files[2].path)
  end)

  it("returns empty list when no untracked files", function()
    stub_run("", 0)
    local files
    git.get_untracked_files("/root", function(f) files = f end)
    assert.same({}, files)
  end)

  it("calls back with nil and notifies on error", function()
    stub_run("", 128, "fatal: not a git repository")
    local notified = false
    local orig_notify = vim.notify
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then notified = true end
    end

    local result = "sentinel"
    git.get_untracked_files("/root", function(f) result = f end)

    vim.notify = orig_notify
    assert.is_nil(result)
    assert.is_true(notified)
  end)
end)

describe("git – get_untracked_file_diff()", function()
  local orig_run

  before_each(function()
    orig_run = git._run
  end)

  after_each(function()
    git._run = orig_run
  end)

  it("calls _run with correct arguments for no-index diff", function()
    local captured_argv
    git._run = function(argv, callback)
      captured_argv = argv
      -- Simulate exit code 1 (files differ) with a valid diff
      callback("--- /dev/null\n+++ b/new.lua\n@@ -0,0 +1 @@\n+hello\n", 1, "")
    end

    local result
    git.get_untracked_file_diff("/root", "new.lua", function(d) result = d end)
    assert.is_not_nil(result)
    assert.truthy(captured_argv)
    -- Should contain --no-index
    local has_no_index = false
    for _, v in ipairs(captured_argv) do
      if v == "--no-index" then has_no_index = true end
    end
    assert.is_true(has_no_index)
  end)
end)
