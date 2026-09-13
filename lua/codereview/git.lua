local M = {}
local DEFAULT_TIMEOUT_MS = 10000
local MAX_COMPARE_JOBS = 8

local function _append_output(chunks, data)
  if not data then return end
  for _, line in ipairs(data) do
    table.insert(chunks, line)
  end
end

local function _join_output(chunks, raw)
  if raw then
    return table.concat(chunks or {})
  end
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
function M._run(argv, callback, opts)
  opts = opts or {}

  -- vim.system preserves NUL bytes and runs argv directly.  Keep the
  -- jobstart fallback for the advertised Neovim 0.9 minimum, where the
  -- channel API normalizes NUL output to line breaks.
  if vim.system then
    local system_opts = { text = true }
    if opts.timeout ~= false then
      system_opts.timeout = opts.timeout or DEFAULT_TIMEOUT_MS
    end
    vim.system(argv, system_opts, function(result)
      vim.schedule(function()
        callback(result.stdout or "", result.code or 1, result.stderr or "")
      end)
    end)
    return
  end

  local stdout = {}
  local stderr = {}
  local finished = false
  local timer

  local function finish(stdout_text, exit_code, stderr_text)
    if finished then return end
    finished = true
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    vim.schedule(function()
      callback(stdout_text, exit_code, stderr_text)
    end)
  end

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
      finish(_join_output(stdout, opts.raw), exit_code, _join_output(stderr, opts.raw))
    end,
  })

  if job_id <= 0 then
    finish("", 127, "codereview: failed to start process")
    return
  end

  if opts.timeout ~= false then
    timer = vim.defer_fn(function()
      if finished then return end
      vim.fn.jobstop(job_id)
      finish("", 124, "codereview: process timed out")
    end, opts.timeout or DEFAULT_TIMEOUT_MS)
  end
end

local function _split_nul(text)
  local result = {}
  for token in (text or ""):gmatch("([^%z]+)") do
    table.insert(result, token)
  end
  return result
end

local function _parse_name_status(text)
  local files = {}
  local nul = text:find("\0", 1, true) ~= nil
  local tokens = nul and _split_nul(text) or vim.split(text, "\n", { trimempty = true })
  -- jobstart() on Neovim 0.9 normalizes NUL bytes to line breaks.  In that
  -- fallback mode Git's status and paths arrive as alternating tokens rather
  -- than tab-separated records.
  local line_format = not nul and tokens[1] and tokens[1]:find("\t", 1, true) ~= nil
  local i = 1

  while i <= #tokens do
    local status = tokens[i]
    local code, inline_path = status:match("^([A-Z]%d*)\t(.*)$")
    code = (code or status:sub(1, 1)):sub(1, 1)
    if nul and (code == "R" or code == "C") then
      if inline_path and tokens[i + 1] then
        table.insert(files, { path = tokens[i + 1], old_path = inline_path, status = code })
        i = i + 2
      elseif tokens[i + 2] then
        table.insert(files, { path = tokens[i + 2], old_path = tokens[i + 1], status = code })
        i = i + 3
      else
        i = i + 1
      end
    elseif not nul and line_format then
      local rstatus, old_path, new_path = status:match("^(R%d*)\t(.+)\t(.+)$")
      if rstatus then
        table.insert(files, { path = new_path, old_path = old_path, status = "R" })
      else
        local plain_code, path = status:match("^([MADRCU])\t(.+)$")
        if plain_code and path then
          table.insert(files, { path = path, status = plain_code })
        end
      end
      i = i + 1
    elseif not nul then
      if (code == "R" or code == "C") and tokens[i + 2] then
        table.insert(files, { path = tokens[i + 2], old_path = tokens[i + 1], status = code })
        i = i + 3
      elseif tokens[i + 1] then
        table.insert(files, { path = tokens[i + 1], status = code })
        i = i + 2
      else
        i = i + 1
      end
    else
      local path
      if nul then
        path = inline_path or tokens[i + 1]
      else
        code, path = status:match("^([MADRCU])\t(.+)$")
      end
      if code and path and code:match("^[MADRCU]$") then
        table.insert(files, { path = path, status = code })
      end
      i = i + (nul and (inline_path and 1 or 2) or 1)
    end
  end

  return files
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
      local ok = pcall(vim.fn.delete, path)
      if not ok then
        vim.notify("codereview: failed to clean up temp file: " .. path, vim.log.levels.WARN)
      end
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
  M._run({ "find", dir, "-type", "f", "-print0" }, function(stdout, exit_code, _)
    if exit_code ~= 0 then
      vim.notify("codereview: failed to scan difftool directories", vim.log.levels.WARN)
      callback(nil)
      return
    end
    callback(stdout:find("\0", 1, true) and _split_nul(stdout)
      or vim.split(stdout, "\n", { trimempty = true }))
  end, { raw = true })
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
  local argv = { "diff", "--name-status", "-z" }
  vim.list_extend(argv, diff_args or {})

  M._run(_git_argv(root, argv), function(stdout, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end

    callback(_parse_name_status(stdout))
  end, { raw = true })
end

-- Get list of untracked files (not yet added to git).
-- Returns via callback: list of { path, status = "?" }
function M.get_untracked_files(root, callback)
  M._run(_git_argv(root, { "ls-files", "--others", "--exclude-standard", "-z" }), function(stdout, exit_code, stderr)
    if exit_code ~= 0 then
      vim.notify(_classify_error(stderr), vim.log.levels.WARN)
      callback(nil)
      return
    end

    local files = {}
    local paths = stdout:find("\0", 1, true) and _split_nul(stdout) or vim.split(stdout, "\n", { trimempty = true })
    for _, path in ipairs(paths) do
      if path ~= "" then
        table.insert(files, { path = path, status = "?" })
      end
    end
    callback(files)
  end, { raw = true })
end

-- Detect which files are binary using git diff --numstat.
-- Returns via callback: table (set) of paths that are binary.
function M.get_binary_files(root, diff_args, callback)
  local argv = { "diff", "--numstat", "--no-renames", "-z" }
  vim.list_extend(argv, diff_args or {})

  M._run(_git_argv(root, argv), function(stdout, exit_code, _)
    if exit_code ~= 0 then
      callback({})
      return
    end

    local binaries = {}
    local records = stdout:find("\0", 1, true) and _split_nul(stdout) or vim.split(stdout, "\n", { trimempty = true })
    for _, line in ipairs(records) do
      local path = line:match("^%-\t%-\t(.+)$")
      if path then
        -- Handle renames: "{prefix/old => prefix/new}" or "old => new"
        local new_path = path:match("=>%s*(.-)%s*}") or path:match("=>%s*(.+)$")
        binaries[new_path or path] = true
      end
    end

    callback(binaries)
  end, { raw = true })
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

  local function run_show(ref)
    local object = ref .. ":" .. path
    M._run(_git_argv(root, { "show", object }), function(content, exit_code, stderr)
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

  local ref = "HEAD"
  if is_staged then
    -- The old side of a staged diff is HEAD; the index contains the new side.
    run_show(ref)
    return
  end

  for _, arg in ipairs(diff_args or {}) do
    if arg == "--" then break end
    if not arg:match("^%-") then
      ref = arg
      break
    end
  end

  local left, right = ref:match("^(.+)%.%.%.(.+)$")
  if left and right then
    M._run(_git_argv(root, { "merge-base", left, right }), function(base, exit_code, stderr)
      if exit_code ~= 0 or vim.trim(base) == "" then
        vim.notify(_classify_error(stderr), vim.log.levels.WARN)
        callback(nil)
      else
        run_show(vim.trim(base))
      end
    end)
    return
  end

  local range_left = ref:match("^(.+)%.%.(.+)$")
  run_show(range_left or ref)
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

-- Get diff for an untracked file (shows entire content as additions).
function M.get_untracked_file_diff(root, path, callback)
  local empty_file = _create_empty_tempfile()
  if not empty_file then
    callback(nil)
    return
  end

  local full_path = root .. "/" .. path
  run_no_index_diff(empty_file, full_path, {
    status = "A",
    old_label = "/dev/null",
    new_label = "b/" .. path,
    cleanup_files = { empty_file },
  }, function(result)
    callback(result.diff)
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
    local compare_tasks = {}
    local active_compares = 0
    local next_task = 1
    local compare_done = false

    local function finish()
      if failed then return end
      if compare_done or active_compares ~= 0 or next_task <= #compare_tasks then return end
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
        table.insert(compare_tasks, { path = rel, local_file = local_file, remote_file = remote_file })
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

    local function start_next()
      while not failed and active_compares < MAX_COMPARE_JOBS and next_task <= #compare_tasks do
        local task = compare_tasks[next_task]
        next_task = next_task + 1
        active_compares = active_compares + 1

        run_no_index_diff(task.local_file, task.remote_file, { notify = false }, function(result)
          active_compares = active_compares - 1
          if failed then
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
              path = task.path,
              status = "M",
              local_file = task.local_file,
              remote_file = task.remote_file,
              is_binary = result.kind == "binary",
            })
          end

          start_next()
          finish()
        end)
      end
    end

    start_next()
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
