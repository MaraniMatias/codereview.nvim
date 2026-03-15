-- Plugin entry point: register commands
if vim.g.loaded_codereview then
  return
end
vim.g.loaded_codereview = true

vim.api.nvim_create_user_command("CodeReview", function(opts)
  require("codereview").open(opts.fargs)
end, {
  nargs = "*",
  desc = "Open codereview code review for current repository",
})

-- :W — save directly to auto-generated filename (no prompt)
vim.api.nvim_create_user_command("W", function()
  require("codereview.review.exporter").save_direct()
end, {
  desc = "Save review directly to auto-generated markdown file",
})
