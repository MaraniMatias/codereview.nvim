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
      callback("", 127, "codereview: failed to start process")
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

local function _classify_no_index_error(stderr)
  if stderr:find("Could not access", 1, true)
      or stderr:find("No such file or directory", 1, true)
      or stderr:find("Permission denied", 1, true) then
    return "codereview: failed to compare files"
  end
  return "codereview: git diff --no-index failed"
end

local function _cleanup_files(paths)
  for _, path in ipairs(paths or {}) do
    if path and path ~= "" then
      pcall(vim.fn.delete, path)
    end
  end
end

local function _normalize_diff_output(stdout, old_label, new_label)
  if not old_label or not new_label then
    return stdout
  end

  local lines = vim.split(stdout, "\n", { plain = true })
  local hunk_start = nil
  for idx, line in ipairs(lines) do
    if line:match("^@@ ") then
      hunk_start = idx
      break
    end
  end

  if not hunk_start then
    return stdout
  end

  local normalized = {
    "--- " .. old_label,
    "+++ " .. new_label,
  }

  for idx = hunk_start, #lines do
    table.insert(normalized, lines[idx])
  end

  return table.concat(normalized, "\n")
end

local function has_binary_marker(text)
  return text and text:find("Binary files ", 1, true) ~= nil and text:find(" differ", 1, true) ~= nil
end

local function is_binary_diff_output(stdout, stderr)
  return has_binary_marker(stdout) or has_binary_marker(stderr)
end

local function build_binary_placeholder(old_label, new_label, status)
  local message = "Binary files differ"
  if status == "A" then
    message = "Binary file added"
  elseif status == "D" then
    message = "Binary file deleted"
  end

  return table.concat({
    "--- " .. old_label,
    "+++ " .. new_label,
    message,
  }, "\n")
end

local function classify_no_index_diff_result(stdout, exit_code, stderr, opts)
  opts = opts or {}
  local old_label = opts.old_label or opts.old_file or "old"
  local new_label = opts.new_label or opts.new_file or "new"
  local trimmed_stderr = vim.trim(stderr or "")

  if exit_code == 0 then
    return { kind = "same", diff = "" }
  end

  if exit_code == 1 then
    if is_binary_diff_output(stdout, stderr) then
      return {
        kind = "binary",
        diff = build_binary_placeholder(old_label, new_label, opts.status),
      }
    end

    if trimmed_stderr ~= "" and stdout == "" then
      return {
        kind = "error",
        diff = nil,
        message = _classify_no_index_error(stderr),
      }
    end

    return {
      kind = "text",
      diff = _normalize_diff_output(stdout, old_label, new_label),
    }
  end

  return {
    kind = "error",
    diff = nil,
    message = _classify_no_index_error(stderr),
  }
end

local function run_no_index_diff(old_file, new_file, opts, callback)
  opts = opts or {}
  local argv = {
    "git",
    "diff",
    "--no-index",
    "--no-ext-diff",
    "--",
    old_file,
    new_file,
  }

  M._run(argv, function(stdout, exit_code, stderr)
    _cleanup_files(opts.cleanup_files)

    local result = classify_no_index_diff_result(stdout, exit_code, stderr, {
      old_file = old_file,
      new_file = new_file,
      old_label = opts.old_label,
      new_label = opts.new_label,
      status = opts.status,
    })

    if result.kind == "error" and opts.notify ~= false then
      vim.notify(result.message, vim.log.levels.WARN)
    end

    callback(result)
  end)
end

local function _create_empty_tempfile()
  local path = vim.fn.tempname()
  local ok = pcall(vim.fn.writefile, {}, path, "b")
  if not ok then
    vim.notify("codereview: failed to create temporary file", vim.log.levels.WARN)
    return nil
  end
  return path
end

local function _to_diff_label(prefix, path)
  local normalized = (path or ""):gsub("\\", "/")
  return prefix .. "/" .. normalized
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
  local segments = vim.split(rel or "", "/", { plain = true, trimempty = true })
  for idx = 1, math.max(#segments - 1, 0) do
    if segments[idx]:sub(1, 1) == "." then
      return false
    end
  end
  return true
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

-- Detect which files are binary using git diff --numstat.
-- Returns via callback: table (set) of paths that are binary.
function M.get_binary_files(root, diff_args, callback)
  local argv = { "diff", "--numstat" }
  vim.list_extend(argv, diff_args or {})

  M._run(_git_argv(root, argv), function(stdout, exit_code, _)
    if exit_code ~= 0 then
      callback({})
      return
    end

    local binaries = {}
    for _, line in ipairs(vim.split(stdout, "\n", { trimempty = true })) do
      local path = line:match("^%-\t%-\t(.+)$")
      if path then
        -- Handle renames: "{prefix/old => prefix/new}" or "old => new"
        local new_path = path:match("=>%s*(.-)%s*}") or path:match("=>%s*(.+)$")
        binaries[vim.trim(new_path or path)] = true
      end
    end

    callback(binaries)
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

-- file_entry: { path, status?, old_path? }
function M.get_file_diff(root, file_entry, diff_args, callback)
  local path = type(file_entry) == "table" and file_entry.path or file_entry
  local clean_args = {}
  for _, arg in ipairs(diff_args or {}) do
    if arg == "--" then break end
    table.insert(clean_args, arg)
  end

  local argv = { "diff", "--no-ext-diff" }
  vim.list_extend(argv, clean_args)
  table.insert(argv, "--")
  if type(file_entry) == "table" and file_entry.status == "R" and file_entry.old_path then
    table.insert(argv, file_entry.old_path)
    table.insert(argv, file_entry.path)
  else
    table.insert(argv, path)
  end

  local status = type(file_entry) == "table" and file_entry.status or nil
  M._run(_git_argv(root, argv), function(result, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end
    if is_binary_diff_output(result, stderr) then
      callback(build_binary_placeholder("a/" .. path, "b/" .. path, status))
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
function M.diff_files(local_file, remote_file, callback, opts)
  run_no_index_diff(local_file, remote_file, opts, function(result)
    callback(result.diff)
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
      if failed then return end
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
        run_no_index_diff(local_file, remote_file, { notify = false }, function(result)
          if failed then
            pending_compares = pending_compares - 1
            finish()
            return
          end

          if result.kind == "error" then
            failed = true
            vim.notify(result.message, vim.log.levels.WARN)
            callback(nil)
            return
          end

          if result.kind ~= "same" then
            table.insert(files, {
              path = rel,
              status = "M",
              local_file = local_file,
              remote_file = remote_file,
              is_binary = result.kind == "binary",
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
  local rel_path = file_entry.path or vim.fn.fnamemodify(file_entry.remote_file or file_entry.local_file or "", ":t")

  if file_entry.status == "A" then
    local empty_file = _create_empty_tempfile()
    if not empty_file then
      callback(nil)
      return
    end

    run_no_index_diff(empty_file, file_entry.remote_file, {
      status = file_entry.status,
      old_label = "/dev/null",
      new_label = _to_diff_label("b", rel_path),
      cleanup_files = { empty_file },
    }, function(result)
      callback(result.diff)
    end)
  elseif file_entry.status == "D" then
    local empty_file = _create_empty_tempfile()
    if not empty_file then
      callback(nil)
      return
    end

    run_no_index_diff(file_entry.local_file, empty_file, {
      status = file_entry.status,
      old_label = _to_diff_label("a", rel_path),
      new_label = "/dev/null",
      cleanup_files = { empty_file },
    }, function(result)
      callback(result.diff)
    end)
  else
    M.diff_files(file_entry.local_file, file_entry.remote_file, callback, {
      status = file_entry.status,
      old_label = _to_diff_label("a", rel_path),
      new_label = _to_diff_label("b", rel_path),
    })
  end
end

return M
