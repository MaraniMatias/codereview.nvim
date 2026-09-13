-- Plugin entry point: register commands
if vim.g.loaded_codereview then
  return
end
vim.g.loaded_codereview = true

if vim.fn.has("nvim-0.9") ~= 1 then
  vim.notify("codereview.nvim requires Neovim 0.9 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("CodeReview", function(opts)
  require("codereview").open(opts.fargs)
end, {
  nargs = "*",
  desc = "Open codereview code review for current repository",
})

local function save_direct()
  require("codereview.review.exporter").save_direct()
end

vim.api.nvim_create_user_command("CodeReviewWrite", save_direct, {
  desc = "Save review directly to auto-generated markdown file when notes exist",
})

-- Keep the historical alias when it is not already owned by the user or another plugin.
if vim.fn.exists(":W") ~= 2 then
  vim.api.nvim_create_user_command("W", save_direct, {
    desc = "Save review directly to auto-generated markdown file when notes exist",
  })
end
