local M = {}

M.defaults = {
	claude_cmd = "claude",
	output_format = "json",
	context = {
		treesitter = true,
		lsp = true,
		lsp_timeout_ms = 2000,
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
