local M = {}

-- Node types that represent a "scope" worth reporting as enclosing context.
-- Keyed by treesitter language name.
local SCOPE_TYPES = {
	-- broad fallback set covers most C-family and scripting languages
	_default = {
		function_definition = true,
		function_declaration = true,
		method_definition = true,
		method_declaration = true,
		arrow_function = true,
		class_definition = true,
		class_declaration = true,
		impl_item = true, -- Rust
		function_item = true, -- Rust
	},
	lua = {
		function_definition = true,
		local_function = true,
		method_definition = true,
	},
	python = {
		function_definition = true,
		async_function_definition = true,
		class_definition = true,
	},
	go = {
		function_declaration = true,
		method_declaration = true,
		type_declaration = true,
	},
}

-- Query strings for collecting import nodes, keyed by language.
-- Each query must capture exactly one node type as @import.
local IMPORT_QUERIES = {
	python = "(import_statement) @import (import_from_statement) @import",
	lua = "(variable_declaration) @import", -- `local x = require(...)` — filtered below
	javascript = "(import_declaration) @import (import_statement) @import",
	typescript = "(import_declaration) @import (import_statement) @import",
	tsx = "(import_declaration) @import",
	go = "(import_declaration) @import",
	rust = "(use_declaration) @import",
	c = "(preproc_include) @import",
	cpp = "(preproc_include) @import",
}

-- Walk up the treesitter AST from `node` and return the first ancestor
-- (or self) whose type is in the language-specific scope set.
local function find_enclosing_scope(node, lang)
	local types = SCOPE_TYPES[lang] or SCOPE_TYPES._default
	local cur = node
	while cur do
		if types[cur:type()] then
			return cur
		end
		cur = cur:parent()
	end
	return nil
end

-- Return the first (signature) line of the node as a string.
local function node_first_line(node, buf)
	local start_row = node:start()
	local lines = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)
	return lines[1] or ""
end

-- Collect treesitter context synchronously.
-- Returns { enclosing_scope: string|nil, imports: string|nil }
function M.get_ts_context(buf, start_line, end_line)
	local result = {}

	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return result
	end

	local tree = parser:parse()[1]
	if not tree then
		return result
	end

	local lang = parser:lang()
	local root = tree:root()

	-- Enclosing scope --------------------------------------------------------
	local node_at_start = root:named_descendant_for_range(start_line, 0, start_line, 0)
	if node_at_start then
		local scope = find_enclosing_scope(node_at_start, lang)
		if scope then
			result.enclosing_scope = node_first_line(scope, buf)
		end
	end

	-- Imports ----------------------------------------------------------------
	local query_src = IMPORT_QUERIES[lang]
	if query_src then
		local ok2, query = pcall(vim.treesitter.query.parse, lang, query_src)
		if ok2 and query then
			local import_lines = {}
			for _, node, _ in query:iter_captures(root, buf, 0, -1) do
				local r = node:start()
				local line = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
				-- For Lua, only keep lines that contain `require`
				if lang ~= "lua" or line:find("require", 1, true) then
					table.insert(import_lines, line)
				end
			end
			if #import_lines > 0 then
				result.imports = table.concat(import_lines, "\n")
			end
		end
	end

	return result
end

-- Collect LSP context asynchronously.
-- Calls on_done({ diagnostics: string|nil, doc_symbols: string|nil })
-- Fires on_done after at most `timeout_ms` milliseconds regardless of LSP state.
function M.get_lsp_context(buf, start_line, end_line, timeout_ms, on_done)
	local result = {}
	local pending = 0
	local done = false

	local function finish()
		if done then
			return
		end
		done = true
		on_done(result)
	end

	-- Check for attached LSP clients -----------------------------------------
	local clients = vim.lsp.get_clients({ bufnr = buf })
	if #clients == 0 then
		finish()
		return
	end

	-- Timeout guard ----------------------------------------------------------
	local uv = vim.uv or vim.loop
	local timer = uv.new_timer()
	timer:start(
		timeout_ms,
		0,
		vim.schedule_wrap(function()
			if not timer:is_closing() then
				timer:stop()
				timer:close()
			end
			finish()
		end)
	)

	local function maybe_finish()
		if pending == 0 then
			if not timer:is_closing() then
				timer:stop()
				timer:close()
			end
			finish()
		end
	end

	-- Diagnostics (synchronous) ----------------------------------------------
	local diag_parts = {}
	for line = start_line, end_line do
		local diags = vim.diagnostic.get(buf, { lnum = line })
		for _, d in ipairs(diags) do
			local src = d.source and ("[" .. d.source .. "] ") or ""
			table.insert(diag_parts, string.format("Line %d: %s%s", line + 1, src, d.message))
		end
	end
	if #diag_parts > 0 then
		result.diagnostics = table.concat(diag_parts, "\n")
	end

	-- Document symbols (async) -----------------------------------------------
	-- Find a client that supports documentSymbol
	local sym_client = nil
	for _, c in ipairs(clients) do
		if c.server_capabilities and c.server_capabilities.documentSymbolProvider then
			sym_client = c
			break
		end
	end

	if sym_client then
		pending = pending + 1
		local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
		sym_client:request("textDocument/documentSymbol", params, function(err, symbols)
			vim.schedule(function()
				if not err and symbols and #symbols > 0 then
					local sym_parts = {}
					-- SymbolInformation (flat) vs DocumentSymbol (nested) — handle both
					local function collect(list, depth)
						depth = depth or 0
						for _, s in ipairs(list) do
							local indent = string.rep("  ", depth)
							local range = s.range or (s.location and s.location.range)
							local lnum = range and (range.start.line + 1) or "?"
							table.insert(sym_parts, string.format("%s%s [line %s]", indent, s.name, lnum))
							if s.children and #s.children > 0 then
								collect(s.children, depth + 1)
							end
						end
					end
					collect(symbols)
					result.doc_symbols = table.concat(sym_parts, "\n")
				end
				pending = pending - 1
				maybe_finish()
			end)
		end, buf)
	end

	-- If no async requests were queued, resolve immediately
	maybe_finish()
end

-- Gather all context. Calls on_done(ctx) where ctx has fields:
--   enclosing_scope, imports, diagnostics, doc_symbols  (all optional strings)
function M.gather(buf, start_line, end_line, timeout_ms, on_done)
	local ctx = M.get_ts_context(buf, start_line, end_line)
	M.get_lsp_context(buf, start_line, end_line, timeout_ms, function(lsp_ctx)
		ctx.diagnostics = lsp_ctx.diagnostics
		ctx.doc_symbols = lsp_ctx.doc_symbols
		on_done(ctx)
	end)
end

return M
