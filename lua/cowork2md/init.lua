local M = {}

local config = require("cowork2md.config")
local state = require("cowork2md.state")
local git = require("cowork2md.git")

--- Setup the plugin with user configuration
function M.setup(opts)
  config.setup(opts)
end

--- Open code review from within Neovim
--- ref: optional git diff ref (e.g. "HEAD", "main..feature", "--staged", "HEAD~3")
function M.open(ref)
  local layout = require("cowork2md.ui.layout")
  if layout.is_open() then
    vim.notify("cowork2md is already open", vim.log.levels.WARN)
    return
  end

  -- Ensure config is initialized with defaults if setup() was never called
  if vim.tbl_isempty(config.options) then
    config.setup({})
  end

  state.init()
  local s = state.get()

  local root = git.get_repo_root()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  s.mode = "review"
  s.root = root
  s.diff_ref = ref or "HEAD"

  local files = git.get_changed_files(root, s.diff_ref)
  if #files == 0 then
    vim.notify("No changed files found (git diff " .. s.diff_ref .. ")", vim.log.levels.INFO)
    return
  end

  for _, f in ipairs(files) do
    f.expanded = false
  end
  s.files = files

  local wins = layout.create()

  local explorer = require("cowork2md.ui.explorer")
  local diff_view = require("cowork2md.ui.diff_view")
  explorer.setup_keymaps(wins.explorer_buf)
  diff_view.setup_keymaps(wins.diff_buf)

  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(1)
  end

  layout.focus_explorer()

  vim.notify(
    "cowork2md: " .. #files .. " changed file(s) | " .. s.diff_ref,
    vim.log.levels.INFO
  )
end

--- Open as git difftool
--- Called from git difftool with LOCAL and REMOTE paths
function M.difftool(local_path, remote_path)
  local layout = require("cowork2md.ui.layout")

  if vim.tbl_isempty(config.options) then
    config.setup({})
  end

  state.init()
  local s = state.get()
  s.mode = "difftool"

  local local_is_dir = vim.fn.isdirectory(local_path) == 1
  local remote_is_dir = vim.fn.isdirectory(remote_path) == 1

  if local_is_dir and remote_is_dir then
    -- --dir-diff mode: scan both directories
    s.local_dir = local_path
    s.remote_dir = remote_path
    s.root = git.get_repo_root(remote_path) or remote_path

    local files = git.scan_dir_diff(local_path, remote_path)
    if #files == 0 then
      vim.notify("No changed files found", vim.log.levels.INFO)
      return
    end
    for _, f in ipairs(files) do
      f.expanded = false
    end
    s.files = files
  else
    -- Single file mode
    local rel_path = vim.fn.fnamemodify(remote_path, ":t")
    s.root = vim.fn.getcwd()
    s.files = {
      {
        path = rel_path,
        status = "M",
        local_file = local_path,
        remote_file = remote_path,
        expanded = false,
      }
    }
  end

  local wins = layout.create()

  local explorer = require("cowork2md.ui.explorer")
  local diff_view = require("cowork2md.ui.diff_view")
  explorer.setup_keymaps(wins.explorer_buf)
  diff_view.setup_keymaps(wins.diff_buf)

  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(1)
  end

  layout.focus_explorer()

  vim.notify(
    "cowork2md difftool: " .. #s.files .. " file(s)",
    vim.log.levels.INFO
  )
end

--- Refresh the current review (re-scan changes)
function M.refresh()
  local s = state.get()
  if not s.mode then return end

  if s.mode == "review" then
    local files = git.get_changed_files(s.root, s.diff_ref)
    for _, f in ipairs(files) do
      f.expanded = false
      for _, existing in ipairs(s.files) do
        if existing.path == f.path then
          f.expanded = existing.expanded
          break
        end
      end
    end
    s.files = files
  elseif s.mode == "difftool" then
    if s.local_dir and s.remote_dir then
      s.files = git.scan_dir_diff(s.local_dir, s.remote_dir)
      for _, f in ipairs(s.files) do
        f.expanded = false
      end
    end
  end

  require("cowork2md.ui.explorer").render()
  require("cowork2md.ui.diff_view").show_file(s.current_file_idx)
  vim.notify("cowork2md: refreshed", vim.log.levels.INFO)
end

return M
