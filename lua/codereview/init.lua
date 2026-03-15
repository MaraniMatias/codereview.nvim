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

local function open_layout(message)
  local layout = require("codereview.ui.layout")
  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  local s = state.get()

  local wins = layout.create()
  explorer.setup_keymaps(wins.explorer_buf)
  diff_view.setup_keymaps(wins.diff_buf)
  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(s.current_file_idx)
  end

  layout.focus_explorer()
  vim.notify(message, vim.log.levels.INFO)
end

local function set_diff_message(message)
  local s = state.get()
  local buf = s.buffers.diff
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  require("codereview.ui.diff_view").clear()
  require("codereview.notes.virtual").clear_extmarks(buf)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { message })
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function restore_expanded_state(files, existing_files)
  local expanded_by_path = {}
  for _, existing in ipairs(existing_files) do
    expanded_by_path[existing.path] = existing.expanded
  end
  for _, file in ipairs(files) do
    file.expanded = expanded_by_path[file.path] or false
  end
end

local function restore_current_file(previous_path)
  local s = state.get()
  if #s.files == 0 then
    s.current_file_idx = 1
    return
  end

  for idx, file in ipairs(s.files) do
    if file.path == previous_path then
      s.current_file_idx = idx
      return
    end
  end

  s.current_file_idx = math.min(math.max(s.current_file_idx, 1), #s.files)
end

--- Setup the plugin with user configuration
function M.setup(opts)
  config.setup(opts)
end

--- Open code review from within Neovim
--- args: optional list of git diff arguments (e.g. {"HEAD"}, {"main..feature"}, {"--staged"}, {"HEAD~3"})
function M.open(args)
  local layout = require("codereview.ui.layout")
  if layout.is_open() or opening then
    vim.notify("codereview is already open", vim.log.levels.WARN)
    return
  end

  ensure_config()
  opening = true

  state.init()
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

      s.files = normalize_files(files)
      s.current_file_idx = 1
      open_layout("codereview: " .. #files .. " changed file(s) | " .. args_display)
    end)
  end)
end

--- Open as git difftool
--- Called from git difftool with LOCAL and REMOTE paths
function M.difftool(local_path, remote_path)
  local layout = require("codereview.ui.layout")
  if layout.is_open() or opening then
    vim.notify("codereview is already open", vim.log.levels.WARN)
    return
  end

  ensure_config()
  opening = true

  state.init()
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
    s.local_dir = local_path
    s.remote_dir = remote_path
    git.get_repo_root(remote_path, function(root)
      s.root = root or remote_path
      git.scan_dir_diff(local_path, remote_path, finish)
    end)
  else
    local rel_path = vim.fn.fnamemodify(remote_path, ":t")
    s.root = vim.fn.getcwd()
    finish({
      {
        path = rel_path,
        status = "M",
        local_file = local_path,
        remote_file = remote_path,
        expanded = false,
      }
    })
  end
end

--- Refresh the current review (re-scan changes)
function M.refresh()
  local s = state.get()
  if not s.mode or refreshing then return end
  refreshing = true

  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  local current_file = s.files[s.current_file_idx]
  local current_path = current_file and current_file.path or nil

  local function apply_refresh(files)
    refreshing = false
    if not files then return end

    if s.mode == "review" then
      restore_expanded_state(files, s.files)
    else
      normalize_files(files)
    end

    s.files = files
    restore_current_file(current_path)
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
    git.get_changed_files(s.root, s.diff_args, apply_refresh)
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
