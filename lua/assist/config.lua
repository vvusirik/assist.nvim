local M = {}

M.defaults = {
	claude_cmd = "claude",
	context = {
		treesitter = true,
		lsp = true,
		lsp_timeout_ms = 2000,
	},
	prompt_buf = {
		width = 60,
		height = 8,
	},
	output_format = "json",
	insert = {
		context_lines = 20,
	},
	select = {
		include_ts_context = true,
		include_lsp_context = true,
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
