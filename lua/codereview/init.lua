local M = {}

local config = require("codereview.config")
local state = require("codereview.state")
local git = require("codereview.git")

--- Setup the plugin with user configuration
function M.setup(opts)
  config.setup(opts)
end

--- Open code review from within Neovim
--- args: optional list of git diff arguments (e.g. {"HEAD"}, {"main..feature"}, {"--staged"}, {"HEAD~3"})
function M.open(args)
  local layout = require("codereview.ui.layout")
  if layout.is_open() then
    vim.notify("codereview is already open", vim.log.levels.WARN)
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
  s.diff_args = args or {}

  local args_display = #s.diff_args > 0 and table.concat(s.diff_args, " ") or "(working tree)"
  local files = git.get_changed_files(root, s.diff_args)
  if files == nil then
    -- git error already notified inside get_changed_files
    return
  end
  if #files == 0 then
    vim.notify("No changed files found (git diff " .. args_display .. ")", vim.log.levels.INFO)
    return
  end

  for _, f in ipairs(files) do
    f.expanded = false
  end
  s.files = files

  local wins = layout.create()

  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  explorer.setup_keymaps(wins.explorer_buf)
  diff_view.setup_keymaps(wins.diff_buf)

  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(1)
  end

  layout.focus_explorer()

  vim.notify(
    "codereview: " .. #files .. " changed file(s) | " .. args_display,
    vim.log.levels.INFO
  )
end

--- Open as git difftool
--- Called from git difftool with LOCAL and REMOTE paths
function M.difftool(local_path, remote_path)
  local layout = require("codereview.ui.layout")

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

  local explorer = require("codereview.ui.explorer")
  local diff_view = require("codereview.ui.diff_view")
  explorer.setup_keymaps(wins.explorer_buf)
  diff_view.setup_keymaps(wins.diff_buf)

  explorer.render()

  if #s.files > 0 then
    diff_view.show_file(1)
  end

  layout.focus_explorer()

  vim.notify(
    "codereview difftool: " .. #s.files .. " file(s)",
    vim.log.levels.INFO
  )
end

--- Refresh the current review (re-scan changes)
function M.refresh()
  local s = state.get()
  if not s.mode then return end

  if s.mode == "review" then
    local files = git.get_changed_files(s.root, s.diff_args)
    if not files then return end
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

  require("codereview.ui.explorer").render()
  require("codereview.ui.diff_view").show_file(s.current_file_idx)
  vim.notify("codereview: refreshed", vim.log.levels.INFO)
end

return M
