local M = {}

local function _append_output(chunks, data)
  if not data then return end
  for _, line in ipairs(data) do
    table.insert(chunks, line)
  end
end

local function _join_output(chunks)
  local lines = vim.deepcopy(chunks or {})
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return table.concat(lines, "\n")
end

local function _git_argv(root, args)
  local argv = { "git" }
  if root then
    table.insert(argv, "-C")
    table.insert(argv, root)
  end
  vim.list_extend(argv, args)
  return argv
end

-- Run a process asynchronously and capture stdout/stderr.
-- Returns: stdout (string), exit_code (number), stderr (string)
function M._run(argv, callback)
  local stdout = {}
  local stderr = {}
  local job_id = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      _append_output(stdout, data)
    end,
    on_stderr = function(_, data)
      _append_output(stderr, data)
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        callback(_join_output(stdout), exit_code, _join_output(stderr))
      end)
    end,
  })

  if job_id <= 0 then
    vim.schedule(function()
      callback("", 1, "codereview: failed to start process")
    end)
  end
end

-- Classify a git stderr message into a human-readable error
local function _classify_error(stderr)
  if stderr:find("not a git repository", 1, true) then
    return "codereview: not a git repository"
  elseif stderr:find("unknown revision", 1, true)
      or stderr:find("bad revision", 1, true)
      or stderr:find("ambiguous argument", 1, true) then
    return "codereview: invalid git ref or revision"
  elseif stderr:find("does not exist in", 1, true)
      or stderr:find("exists on disk, but not in", 1, true) then
    return "codereview: path does not exist in the given ref"
  else
    return "codereview: git command failed"
  end
end

local function _scan_dir(dir, callback)
  M._run({ "find", dir, "-type", "f" }, function(stdout, exit_code, _)
    if exit_code ~= 0 then
      vim.notify("codereview: failed to scan difftool directories", vim.log.levels.WARN)
      callback(nil)
      return
    end
    callback(vim.split(stdout, "\n", { trimempty = true }))
  end)
end

local function _is_visible_difftool_path(rel)
  return not rel:match("^%.git/")
end

-- Get the git repository root from a given path.
-- Returns root path string or nil.
function M.get_repo_root(path, callback)
  local cwd = path or vim.fn.getcwd()
  M._run(_git_argv(cwd, { "rev-parse", "--show-toplevel" }), function(stdout, exit_code, _)
    local result = vim.trim(stdout)
    if exit_code ~= 0 or result == "" then
      callback(nil)
      return
    end
    callback(result)
  end)
end

-- Get list of changed files with their status.
-- diff_args: list of git diff arguments (e.g. {"HEAD"}, {"--staged"}, {"main..feature"})
-- Returns via callback: list of { path, status } where status is "M", "A", "D", "R", "C", "U"
function M.get_changed_files(root, diff_args, callback)
  local argv = { "diff", "--name-status" }
  vim.list_extend(argv, diff_args or {})

  M._run(_git_argv(root, argv), function(stdout, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end

    local lines = vim.split(stdout, "\n", { trimempty = true })
    local files = {}
    for _, line in ipairs(lines) do
      local rstatus, old_path, new_path = line:match("^(R%d*)\t(.+)\t(.+)$")
      if rstatus then
        table.insert(files, { path = new_path, old_path = old_path, status = "R" })
      else
        local status, path = line:match("^([MADRCU])\t(.+)$")
        if status and path then
          table.insert(files, { path = path, status = status })
        end
      end
    end

    callback(files)
  end)
end

-- Get the old content of a file (before changes).
-- diff_args: list of git diff arguments used for this review session.
-- Returns via callback: string content or nil.
function M.get_file_old(root, path, diff_args, callback)
  local is_staged = false
  for _, arg in ipairs(diff_args or {}) do
    if arg == "--staged" or arg == "--cached" then
      is_staged = true
      break
    end
  end

  local argv
  if is_staged then
    argv = { "show", ":" .. path }
  else
    local ref = "HEAD"
    for _, arg in ipairs(diff_args or {}) do
      if not arg:match("^%-") then
        ref = arg
        break
      end
    end
    argv = { "show", ref .. ":" .. path }
  end

  M._run(_git_argv(root, argv), function(content, exit_code, stderr)
    if exit_code ~= 0 then
      if not stderr:find("exists on disk, but not in", 1, true)
          and not stderr:find("does not exist in", 1, true) then
        vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      end
      callback(nil)
      return
    end
    callback(content)
  end)
end

-- Get unified diff for a single file.
-- diff_args: list of git diff arguments; any existing "-- path" tokens are stripped.
-- Returns via callback: diff string.
function M.get_file_diff(root, path, diff_args, callback)
  local clean_args = {}
  for _, arg in ipairs(diff_args or {}) do
    if arg == "--" then break end
    table.insert(clean_args, arg)
  end

  local argv = { "diff" }
  vim.list_extend(argv, clean_args)
  table.insert(argv, "--")
  table.insert(argv, path)

  M._run(_git_argv(root, argv), function(result, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end
    callback(result)
  end)
end

-- Get diff for staged changes.
function M.get_staged_diff(root, path, callback)
  M._run(_git_argv(root, { "diff", "--cached", "--", path }), function(result, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end
    callback(result)
  end)
end

-- Get diff between two files (for difftool mode).
-- local_file: path to old version, remote_file: path to new version.
-- Returns via callback: diff string.
function M.diff_files(local_file, remote_file, callback)
  M._run({ "diff", "-u", local_file, remote_file }, function(result, exit_code, _)
    if exit_code == 2 then
      callback(nil)
      return
    end
    callback(result)
  end)
end

-- Scan two directories (local/remote) for difftool --dir-diff mode.
-- Returns via callback: list of { path, status, local_file, remote_file }, sorted by path.
-- Note: rename detection is not possible in --dir-diff mode without git metadata;
-- only A/D/M statuses are reported. Identical files are excluded.
function M.scan_dir_diff(local_dir, remote_dir, callback)
  local listings = {}
  local completed_scans = 0
  local failed = false

  local function on_scan_done(kind, files)
    if failed then return end
    if files == nil then
      failed = true
      callback(nil)
      return
    end

    listings[kind] = files
    completed_scans = completed_scans + 1
    if completed_scans < 2 then return end

    local local_index = {}
    local remote_index = {}
    for _, fpath in ipairs(listings["local"]) do
      local rel = fpath:sub(#local_dir + 2)
      if _is_visible_difftool_path(rel) then
        local_index[rel] = fpath
      end
    end
    for _, fpath in ipairs(listings["remote"]) do
      local rel = fpath:sub(#remote_dir + 2)
      if _is_visible_difftool_path(rel) then
        remote_index[rel] = fpath
      end
    end

    local files = {}
    local pending_compares = 0
    local compare_done = false

    local function finish()
      if compare_done or pending_compares ~= 0 then return end
      compare_done = true
      table.sort(files, function(a, b) return a.path < b.path end)
      callback(files)
    end

    for rel, remote_file in pairs(remote_index) do
      local local_file = local_index[rel]
      if not local_file then
        table.insert(files, {
          path = rel,
          status = "A",
          local_file = local_dir .. "/" .. rel,
          remote_file = remote_file,
        })
      else
        pending_compares = pending_compares + 1
        M._run({ "diff", "-q", local_file, remote_file }, function(_, exit_code, _)
          if exit_code ~= 0 then
            table.insert(files, {
              path = rel,
              status = "M",
              local_file = local_file,
              remote_file = remote_file,
            })
          end

          pending_compares = pending_compares - 1
          finish()
        end)
      end
    end

    for rel, local_file in pairs(local_index) do
      if not remote_index[rel] then
        table.insert(files, {
          path = rel,
          status = "D",
          local_file = local_file,
          remote_file = nil,
        })
      end
    end

    finish()
  end

  _scan_dir(local_dir, function(files)
    on_scan_done("local", files)
  end)
  _scan_dir(remote_dir, function(files)
    on_scan_done("remote", files)
  end)
end

-- Get diff content for a FileEntry in difftool mode.
function M.get_difftool_diff(file_entry, callback)
  if file_entry.status == "A" then
    M._run({ "diff", "-u", "/dev/null", file_entry.remote_file }, function(result, _, _)
      callback(result)
    end)
  elseif file_entry.status == "D" then
    M._run({ "diff", "-u", file_entry.local_file, "/dev/null" }, function(result, _, _)
      callback(result)
    end)
  else
    M.diff_files(file_entry.local_file, file_entry.remote_file, callback)
  end
end

return M
