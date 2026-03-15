local M = {}

local config = require("codereview.config")
local state = require("codereview.state")
local git = require("codereview.git")
local opening = false
local refreshing = false

local function ensure_config()
  if vim.tbl_isempty(config.options) then
    config.setup({})
  end
end

local function normalize_files(files)
  for _, file in ipairs(files) do
    if file.expanded == nil then
      file.expanded = false
    end
  end
  return files
end

local function mark_binary_files(files, binaries)
  for _, file in ipairs(files) do
    if binaries[file.path] then
      file.is_binary = true
    end
  end
end

local function open_layout(message)
  local layout = require("codereview.ui.layout")
  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  local s = state.get()

  local wins = layout.create()
  explorer.setup_keymaps(wins.explorer_buf)
  if wins.diff_buf then
    diff_view.setup_keymaps(wins.diff_buf)
  end
  if wins.diff_old_buf then
    diff_view.setup_keymaps(wins.diff_old_buf)
  end
  if wins.diff_new_buf then
    diff_view.setup_keymaps(wins.diff_new_buf)
  end
  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(s.current_file_idx)
  end

  layout.focus_explorer()
  vim.notify(message, vim.log.levels.INFO)
end

local function set_diff_message(message)
  local s = state.get()
  local diff_view = require("codereview.ui.diff_view")
  local virt = require("codereview.notes.virtual")
  diff_view.clear()

  local function set_msg(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    virt.clear_extmarks(buf)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { message })
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end

  if diff_view.is_split_mode() then
    set_msg(s.buffers.diff_old)
    set_msg(s.buffers.diff_new)
  else
    set_msg(s.buffers.diff)
  end
end

local function _add_candidate(candidates, seen, path)
  if path and path ~= "" and not seen[path] then
    seen[path] = true
    table.insert(candidates, path)
  end
end

local function _file_identity_candidates(file)
  if not file then return {} end
  local candidates = {}
  local seen = {}
  _add_candidate(candidates, seen, file.path)
  _add_candidate(candidates, seen, file.old_path)
  return candidates
end

local function _files_share_identity(lhs, rhs)
  if not lhs or not rhs then
    return false
  end

  local identities = {}
  for _, candidate in ipairs(_file_identity_candidates(lhs)) do
    identities[candidate] = true
  end

  for _, candidate in ipairs(_file_identity_candidates(rhs)) do
    if identities[candidate] then
      return true
    end
  end

  return false
end

local function restore_expanded_state(files, existing_files)
  for _, file in ipairs(files) do
    file.expanded = false
    for _, existing in ipairs(existing_files) do
      if _files_share_identity(file, existing) then
        file.expanded = existing.expanded or false
        break
      end
    end
  end
end

local function restore_current_file(previous_file)
  local s = state.get()
  if #s.files == 0 then
    s.current_file_idx = 1
    return
  end

  for idx, file in ipairs(s.files) do
    if _files_share_identity(file, previous_file) then
      s.current_file_idx = idx
      return
    end
  end

  s.current_file_idx = math.min(math.max(s.current_file_idx, 1), #s.files)
end

--- Setup the plugin with user configuration.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
end

--- Open code review from within Neovim.
---@param args string[]|nil Optional git diff arguments, e.g. {"HEAD"}, {"--staged"}
function M.open(args)
  local layout = require("codereview.ui.layout")
  if layout.is_open() or opening then
    vim.notify("codereview is already open", vim.log.levels.WARN)
    return
  end

  ensure_config()
  opening = true

  state.init()
  require("codereview.notes.store").reset_cache()
  local s = state.get()
  s.mode = "review"
  s.diff_args = args or {}

  local args_display = #s.diff_args > 0 and table.concat(s.diff_args, " ") or "(working tree)"

  git.get_repo_root(nil, function(root)
    if not root then
      opening = false
      state.reset()
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return
    end

    s.root = root
    git.get_changed_files(root, s.diff_args, function(files)
      opening = false
      if files == nil then
        state.reset()
        return
      end
      if #files == 0 then
        state.reset()
        vim.notify("No changed files found (git diff " .. args_display .. ")", vim.log.levels.INFO)
        return
      end

      git.get_binary_files(root, s.diff_args, function(binaries)
        mark_binary_files(files, binaries)
        s.files = normalize_files(files)
        s.current_file_idx = 1
        local view_label = config.options.diff_view == "split" and " [split]" or ""
        open_layout("codereview" .. view_label .. ": " .. #files .. " changed file(s) | " .. args_display)
      end)
    end)
  end)
end

--- Open as git difftool ($LOCAL / $REMOTE paths).
---@param local_path string Absolute path to old file ($LOCAL)
---@param remote_path string Absolute path to new file ($REMOTE)
---@param merged_path string|nil Optional $MERGED path for stable identity
function M.difftool(local_path, remote_path, merged_path)
  local layout = require("codereview.ui.layout")
  if layout.is_open() or opening then
    vim.notify("codereview is already open", vim.log.levels.WARN)
    return
  end

  ensure_config()
  opening = true

  state.init()
  require("codereview.notes.store").reset_cache()
  local s = state.get()
  s.mode = "difftool"

  local local_is_dir = vim.fn.isdirectory(local_path) == 1
  local remote_is_dir = vim.fn.isdirectory(remote_path) == 1

  local function finish(files)
    opening = false
    if files == nil then
      state.reset()
      return
    end
    if #files == 0 then
      state.reset()
      vim.notify("No changed files found", vim.log.levels.INFO)
      return
    end

    s.files = normalize_files(files)
    s.current_file_idx = 1
    open_layout("codereview difftool: " .. #s.files .. " file(s)")
  end

  if local_is_dir and remote_is_dir then
    s.single_file_difftool = false
    s.local_dir = local_path
    s.remote_dir = remote_path
    git.get_repo_root(remote_path, function(root)
      s.root = root or remote_path
      git.scan_dir_diff(local_path, remote_path, finish)
    end)
  else
    s.single_file_difftool = true
    -- Resolve merged path: explicit arg > CODEREVIEW_MERGED env > MERGED env (set by git)
    local merged = (merged_path and merged_path ~= "" and merged_path)
      or (vim.env.CODEREVIEW_MERGED ~= "" and vim.env.CODEREVIEW_MERGED or nil)
      or (vim.env.MERGED and vim.env.MERGED ~= "" and vim.env.MERGED or nil)

    local function inject_and_open(rel, local_p, remote_p)
      git.get_changed_files(s.root, {}, function(all_files)
        all_files = all_files or {}
        local current_idx = 1
        local found = false
        for i, f in ipairs(all_files) do
          if f.path == rel then
            f.local_file = local_p
            f.remote_file = remote_p
            current_idx = i
            found = true
            break
          end
        end
        if not found then
          table.insert(all_files, 1, {
            path = rel, status = "M",
            local_file = local_p, remote_file = remote_p,
            expanded = false,
          })
          current_idx = 1
        end
        opening = false
        if #all_files == 0 then
          state.reset()
          vim.notify("No changed files found", vim.log.levels.INFO)
          return
        end
        git.get_binary_files(s.root, {}, function(binaries)
          mark_binary_files(all_files, binaries)
          s.files = normalize_files(all_files)
          s.current_file_idx = current_idx
          open_layout("codereview difftool: " .. #s.files .. " file(s)")
        end)
      end)
    end

    if merged then
      -- Derive repo-relative path from $MERGED for stable, collision-free identity
      git.get_repo_root(vim.fn.fnamemodify(merged, ":h"), function(root)
        local rel
        if root and merged:sub(1, #root) == root then
          rel = merged:sub(#root + 2)   -- strip "root/" prefix
          s.root = root
        else
          -- git root not found: use $MERGED basename (better than temp path basename)
          rel = vim.fn.fnamemodify(merged, ":t")
          s.root = vim.fn.getcwd()
        end
        inject_and_open(rel, local_path, remote_path)
      end)
    else
      -- Fallback without $MERGED: use basename of remote_path (original behavior)
      local rel_path = vim.fn.fnamemodify(remote_path, ":t")
      s.root = vim.fn.getcwd()
      inject_and_open(rel_path, local_path, remote_path)
    end
  end
end

--- Refresh the current review (re-scan changed files). No-op if nothing is open.
---@return nil
function M.refresh()
  local s = state.get()
  if not s.mode or refreshing then return end
  refreshing = true

  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  local current_file = s.files[s.current_file_idx]

  local function apply_refresh(files)
    refreshing = false
    if not files then return end

    if s.mode == "review" then
      restore_expanded_state(files, s.files)
    else
      normalize_files(files)
    end

    s.files = files
    restore_current_file(current_file)
    explorer.render()

    if #s.files == 0 then
      set_diff_message("  (no changed files)")
      vim.notify("codereview: no changed files after refresh", vim.log.levels.INFO)
      return
    end

    diff_view.show_file(s.current_file_idx)
    vim.notify("codereview: refreshed", vim.log.levels.INFO)
  end

  if s.mode == "review" then
    git.get_changed_files(s.root, s.diff_args, function(files)
      if not files then
        apply_refresh(nil)
        return
      end
      git.get_binary_files(s.root, s.diff_args, function(binaries)
        mark_binary_files(files, binaries)
        apply_refresh(files)
      end)
    end)
  elseif s.mode == "difftool" and s.local_dir and s.remote_dir then
    git.scan_dir_diff(s.local_dir, s.remote_dir, apply_refresh)
  else
    refreshing = false
    explorer.render()
    diff_view.show_file(s.current_file_idx)
    vim.notify("codereview: refreshed", vim.log.levels.INFO)
  end
end

return M
