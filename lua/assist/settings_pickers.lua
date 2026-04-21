local config = require("assist.config")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M = {}

function M.pick_model(opts)
	opts = opts or {}
	local models = { "default", "opus", "sonnet", "haiku" }
	pickers
		.new(opts, {
			prompt_title = "Select Model",
			finder = finders.new_table({ results = models }),
			sorter = conf.generic_sorter(opts),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					config.options.model = selection[1]
					vim.notify("assist.nvim: model set to " .. selection[1])
				end)
				return true
			end,
		})
		:find()
end

function M.pick_conversation(opts)
	-- TODO
end

return M
