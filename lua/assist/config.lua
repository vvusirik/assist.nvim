local M = {}

M.defaults = {
	claude_cmd = "claude",
	prompt_buf = {
		width = 60,
		height = 8,
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
