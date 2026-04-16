-- startup command
if vim.g.loaded_assist then
	return
end
vim.g.loaded_assist = true

local assist = require("assist")
local multi = require("assist.multi")

vim.api.nvim_create_user_command("AssistPrompt", function(opts)
	assist.assist_visual_selection(opts.line1, opts.line2)
end, { range = true, desc = "Prompt AI to implement the selected code region" })

vim.api.nvim_create_user_command("AssistInsert", function()
	assist.assist_normal()
end, { desc = "Prompt AI to generate and insert a snippet at the cursor" })

vim.api.nvim_create_user_command("AssistMulti", function()
	multi.assist_multi()
end, { desc = "Propose multi-file AI edits via quickfix + diff review" })
