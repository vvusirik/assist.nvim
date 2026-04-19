-- startup command
if vim.g.loaded_assist then
	return
end
vim.g.loaded_assist = true

local select = require("assist.select")
local insert = require("assist.insert")
local multi = require("assist.multi")
local ask = require("assist.ask")

vim.api.nvim_create_user_command("AssistSelect", function(opts)
	select.assist_visual_selection(opts.line1, opts.line2)
end, { range = true, desc = "Prompt AI to implement the selected code region" })

vim.api.nvim_create_user_command("AssistInsert", function()
	insert.assist_normal()
end, { desc = "Prompt AI to generate and insert a snippet at the cursor" })

vim.api.nvim_create_user_command("AssistMulti", function()
	multi.assist_multi()
end, { desc = "Propose multi-file AI edits via quickfix + diff review" })

vim.api.nvim_create_user_command("AssistAsk", function(opts)
	if opts.range > 0 then
		ask.assist_ask_selection(opts.line1, opts.line2)
	else
		ask.assist_ask_normal()
	end
end, { range = true, desc = "Ask AI a question and get the response inline" })
