-- startup command
if vim.g.loaded_assist then return end
vim.g.loaded_assist = true

local assist = require("assist")

vim.api.nvim_create_user_command("AssistPrompt", function()
  assist.assist_prompt()
end, { range = true, desc = "Prompt AI to implement the selected code region" })
