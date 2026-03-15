local M = {}

-- Convert a list of diff args to a safe shell string
-- Returns empty string if args_list is nil or empty
function M._args_str(args_list)
  if not args_list or #args_list == 0 then return "" end
  local escaped = vim.tbl_map(vim.fn.shellescape, args_list)
  return table.concat(escaped, " ")
end

-- Get the git repository root from a given path
-- Returns root path string or nil
function M.get_repo_root(path)
  local result = vim.fn.system(
    "git -C " .. vim.fn.shellescape(path or vim.fn.getcwd()) .. " rev-parse --show-toplevel 2>/dev/null"
  )
  result = vim.trim(result)
  if vim.v.shell_error ~= 0 or result == "" then
    return nil
  end
  return result
end

-- Get list of changed files with their status
-- diff_args: list of git diff arguments (e.g. {"HEAD"}, {"--staged"}, {"main..feature"})
-- Returns: list of { path, status } where status is "M", "A", "D", "R", "C", "U"
function M.get_changed_files(root, diff_args)
  local args_str = M._args_str(diff_args)
  local cmd = "git -C " .. vim.fn.shellescape(root) ..
    " diff --name-status " .. args_str .. " 2>/dev/null"
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("codereview: git diff failed (invalid ref or not a repository)", vim.log.levels.WARN)
    return {}
  end

  local files = {}
  for _, line in ipairs(lines) do
    -- Handle rename: R100\told_path\tnew_path
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
  return files
end

-- Get the old content of a file (before changes)
-- diff_args: list of git diff arguments used for this review session
-- Returns: string content or nil
function M.get_file_old(root, path, diff_args)
  local is_staged = false
  for _, arg in ipairs(diff_args or {}) do
    if arg == "--staged" or arg == "--cached" then
      is_staged = true
      break
    end
  end

  local cmd
  if is_staged then
    -- Read from the index (staged version of old file)
    cmd = "git -C " .. vim.fn.shellescape(root) ..
      " show :" .. vim.fn.shellescape(path) .. " 2>/dev/null"
  else
    -- Find first non-flag arg as ref; default to HEAD
    local ref = "HEAD"
    for _, arg in ipairs(diff_args or {}) do
      if not arg:match("^%-") then
        ref = arg
        break
      end
    end
    cmd = "git -C " .. vim.fn.shellescape(root) ..
      " show " .. ref .. ":" .. vim.fn.shellescape(path) .. " 2>/dev/null"
  end

  local content = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return content
end

-- Get unified diff for a single file
-- diff_args: list of git diff arguments; any existing "-- path" tokens are stripped
-- Returns: diff string
function M.get_file_diff(root, path, diff_args)
  -- Strip any "-- <path>" suffix from diff_args (we append our own)
  local clean_args = {}
  for _, arg in ipairs(diff_args or {}) do
    if arg == "--" then break end
    table.insert(clean_args, arg)
  end
  local args_str = M._args_str(clean_args)
  local cmd = "git -C " .. vim.fn.shellescape(root) ..
    " diff " .. args_str .. " -- " .. vim.fn.shellescape(path) .. " 2>/dev/null"
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 and result == "" then
    return nil
  end
  return result
end

-- Get diff for staged changes
function M.get_staged_diff(root, path)
  local cmd = "git -C " .. vim.fn.shellescape(root) ..
    " diff --cached -- " .. vim.fn.shellescape(path) .. " 2>/dev/null"
  local result = vim.fn.system(cmd)
  return result
end

-- Get diff between two files (for difftool mode)
-- local_file: path to old version, remote_file: path to new version
-- Returns: diff string
function M.diff_files(local_file, remote_file)
  local cmd = "diff -u " .. vim.fn.shellescape(local_file) ..
    " " .. vim.fn.shellescape(remote_file) .. " 2>/dev/null"
  local result = vim.fn.system(cmd)
  -- diff returns exit code 1 when files differ (normal), 0 when same, 2 on error
  if vim.v.shell_error == 2 then
    return nil
  end
  return result
end

-- Scan two directories (local/remote) for difftool --dir-diff mode
-- Returns: list of { path, status, local_file, remote_file }, sorted by path
-- Note: rename detection is not possible in --dir-diff mode without git metadata;
-- only A/D/M statuses are reported. Identical files are excluded.
function M.scan_dir_diff(local_dir, remote_dir)
  local files = {}
  local seen = {}

  -- Get all files in remote dir (new/modified)
  local remote_files = vim.fn.systemlist(
    "find " .. vim.fn.shellescape(remote_dir) .. " -type f 2>/dev/null"
  )
  for _, fpath in ipairs(remote_files) do
    local rel = fpath:sub(#remote_dir + 2)  -- strip remote_dir/ prefix
    if not rel:match("^%.git/") then
      local local_file = local_dir .. "/" .. rel
      local status
      if vim.fn.filereadable(local_file) == 1 then
        -- Check if files are identical; skip if so
        vim.fn.system("diff -q " .. vim.fn.shellescape(local_file) ..
          " " .. vim.fn.shellescape(fpath) .. " 2>/dev/null")
        if vim.v.shell_error == 0 then
          seen[rel] = true
          goto continue
        end
        status = "M"
      else
        status = "A"
      end
      table.insert(files, {
        path = rel,
        status = status,
        local_file = local_file,
        remote_file = fpath,
      })
      seen[rel] = true
      ::continue::
    end
  end

  -- Get files only in local dir (deleted)
  local local_files = vim.fn.systemlist(
    "find " .. vim.fn.shellescape(local_dir) .. " -type f 2>/dev/null"
  )
  for _, fpath in ipairs(local_files) do
    local rel = fpath:sub(#local_dir + 2)
    if not rel:match("^%.git/") and not seen[rel] then
      table.insert(files, {
        path = rel,
        status = "D",
        local_file = fpath,
        remote_file = nil,
      })
    end
  end

  -- Sort results alphabetically by path
  table.sort(files, function(a, b) return a.path < b.path end)

  return files
end

-- Get diff content for a FileEntry in difftool mode
function M.get_difftool_diff(file_entry)
  if file_entry.status == "A" then
    -- New file: diff against /dev/null
    local cmd = "diff -u /dev/null " .. vim.fn.shellescape(file_entry.remote_file) .. " 2>/dev/null"
    local result = vim.fn.system(cmd)
    return result
  elseif file_entry.status == "D" then
    -- Deleted file: diff against /dev/null
    local cmd = "diff -u " .. vim.fn.shellescape(file_entry.local_file) .. " /dev/null 2>/dev/null"
    local result = vim.fn.system(cmd)
    return result
  else
    return M.diff_files(file_entry.local_file, file_entry.remote_file)
  end
end

return M
