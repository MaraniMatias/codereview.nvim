-- Plugin entry point: register commands
if vim.g.loaded_cowork2md then
  return
end
vim.g.loaded_cowork2md = true

vim.api.nvim_create_user_command("CodeReview", function(opts)
  local args = opts.args
  require("cowork2md").open(args ~= "" and args or nil)
end, {
  nargs = "?",
  desc = "Open cowork2md code review for current repository",
})

vim.api.nvim_create_user_command("CoworkSave", function()
  require("cowork2md.review.exporter").save_with_prompt()
end, {
  desc = "Save current review notes to markdown file",
})
