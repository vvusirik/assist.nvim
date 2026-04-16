-- startup command
if vim.g.loaded_assist then
	return
end
vim.g.loaded_assist = true

local assist = require("assist")

vim.api.nvim_create_user_command("AssistPrompt", function(opts)
	assist.assist_visual_selection(opts.line1, opts.line2)
end, { range = true, desc = "Prompt AI to implement the selected code region" })

vim.api.nvim_create_user_command("AssistInsert", function()
	assist.assist_normal()
end, { desc = "Prompt AI to generate and insert a snippet at the cursor" })
