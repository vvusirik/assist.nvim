local M = {}

M.defaults = {
	claude_cmd = "claude",
	model = "default",
	prompt_buf = {
		width = 100,
		height = 8,
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
