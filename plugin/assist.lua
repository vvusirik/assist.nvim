-- startup command
if vim.g.loaded_assist then
	return
end
vim.g.loaded_assist = true

local select = require("assist.select")
local insert = require("assist.insert")
local multi = require("assist.multi")
local ask = require("assist.ask")
local complete = require("assist.complete")
local settings_pickers = require("assist.settings_pickers")

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

vim.api.nvim_create_user_command("AssistExplain", function(opts)
	ask.assist_explain(opts.line1, opts.line2)
end, { range = true, desc = "Ask AI to explain a section of code" })

vim.api.nvim_create_user_command("AssistComplete", function()
	complete.assist_insert_completion()
end, { desc = "Generate and propose code completion suggestions" })

vim.api.nvim_create_user_command("AssistPickModel", function()
	settings_pickers.pick_model()
end, { desc = "Pick the Claude model to use for assist commands" })
