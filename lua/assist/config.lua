local M = {}

M.defaults = {
  claude_cmd = "claude",
  output_format = "json",
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
