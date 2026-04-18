local config = require("assist.config")
local utils = require("assist.utils")
local context = require("assist.context")

local M = {}

-- Get cursor position and surrounding lines for normal-mode insert.
local function get_normal_insert_info()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1] - 1 -- 0-indexed
	local total = vim.api.nvim_buf_line_count(buf)

	local above = ""
	local below = ""
	local context_lines = config.insert.context_lines
	if context_lines > 0 then
		local above_start = math.max(0, cursor_line - context_lines)
		local below_end = math.min(total, cursor_line + context_lines + 1)
		above = table.concat(vim.api.nvim_buf_get_lines(buf, above_start, cursor_line, false), "\n")
		below = table.concat(vim.api.nvim_buf_get_lines(buf, cursor_line + 1, below_end, false), "\n")
	end

	return {
		buf = buf,
		cursor_line = cursor_line,
		above = above,
		below = below,
	}
end

local function build_insert_prompt(insert_info, user_prompt, file_path, lang, ctx)
	local parts = {
		"<task>Generate a code snippet to insert at the cursor position. Output ONLY the new snippet using the Write tool — do not print it as text.</task>",
		string.format(
			"<file path=%q language=%q cursor_line=%q/>",
			file_path,
			lang,
			tostring(insert_info.cursor_line + 1)
		),
	}

	local surrounding_parts = {}
	if insert_info.above ~= "" then
		table.insert(
			surrounding_parts,
			string.format("<above_cursor>\n```%s\n%s\n```\n</above_cursor>", lang, insert_info.above)
		)
	end
	if insert_info.below ~= "" then
		table.insert(
			surrounding_parts,
			string.format("<below_cursor>\n```%s\n%s\n```\n</below_cursor>", lang, insert_info.below)
		)
	end
	if #surrounding_parts > 0 then
		table.insert(
			parts,
			"<surrounding_context>\n" .. table.concat(surrounding_parts, "\n") .. "\n</surrounding_context>"
		)
	end

	if ctx then
		local ctx_parts = {}
		if ctx.enclosing_scope then
			table.insert(
				ctx_parts,
				string.format("<enclosing_scope>\n```%s\n%s\n```\n</enclosing_scope>", lang, ctx.enclosing_scope)
			)
		end
		if ctx.imports then
			table.insert(ctx_parts, string.format("<imports>\n```%s\n%s\n```\n</imports>", lang, ctx.imports))
		end
		if ctx.diagnostics then
			table.insert(ctx_parts, string.format("<diagnostics>\n%s\n</diagnostics>", ctx.diagnostics))
		end
		if ctx.doc_symbols then
			table.insert(ctx_parts, string.format("<doc_symbols>\n%s\n</doc_symbols>", ctx.doc_symbols))
		end
		if #ctx_parts > 0 then
			table.insert(parts, "<context>\n" .. table.concat(ctx_parts, "\n") .. "\n</context>")
		end
	end

	table.insert(parts, string.format("<instructions>%s</instructions>", user_prompt))
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function run_assist_insert(insert_info, user_prompt)
	local buf = insert_info.buf
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local opts = config.options
	local ctx_cfg = opts.context or {}
	local cursor_line = insert_info.cursor_line

	local spinner = utils.start_spinner(buf, { { line = cursor_line } }, "Generating...")

	local function start_job(ctx)
		local prompt = build_insert_prompt(insert_info, user_prompt, file_path, lang, ctx)
		local stdout_lines = {}
		local stderr_lines = {}

		local job_id = vim.fn.jobstart({ opts.claude_cmd, "--print", "--output-format", opts.output_format, prompt }, {
			stdout_buffered = false,
			stderr_buffered = false,
			on_stdout = function(_, lines)
				for _, line in ipairs(lines) do
					if line ~= "" then
						table.insert(stdout_lines, line)
					end
				end
			end,
			on_stderr = function(_, lines)
				for _, line in ipairs(lines) do
					if line ~= "" then
						table.insert(stderr_lines, line)
					end
				end
			end,
			on_exit = function(_, code)
				vim.schedule(function()
					local positions = spinner.positions()
					spinner.stop()

					if code ~= 0 then
						local stderr_out = table.concat(stderr_lines, "\n")
						vim.notify(
							"[assist.nvim] claude exited with code "
								.. code
								.. (stderr_out ~= "" and (": " .. stderr_out) or ""),
							vim.log.levels.ERROR
						)
						return
					end

					local raw = table.concat(stdout_lines, "\n")
					local result, err = utils.parse_claude_response(raw)
					if err then
						vim.notify("[assist.nvim] " .. err, vim.log.levels.ERROR)
						return
					end

					local insert_after = (positions[1] and positions[1][1]) or cursor_line
					local new_lines = vim.split(result, "\n", { plain = true })
					vim.api.nvim_buf_set_lines(buf, insert_after + 1, insert_after + 1, false, new_lines)
					vim.notify("[assist.nvim] Done.", vim.log.levels.INFO)
				end)
			end,
		})

		if job_id <= 0 then
			spinner.stop()
			vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
			return
		end

		vim.fn.chanclose(job_id, "stdin")
	end

	if ctx_cfg.treesitter or ctx_cfg.lsp then
		context.gather(buf, cursor_line, cursor_line, ctx_cfg.lsp_timeout_ms or 2000, function(ctx)
			if not ctx_cfg.treesitter then
				ctx.enclosing_scope = nil
				ctx.imports = nil
			end
			if not ctx_cfg.lsp then
				ctx.diagnostics = nil
				ctx.doc_symbols = nil
			end
			start_job(ctx)
		end)
	else
		start_job(nil)
	end
end

function M.assist_normal()
	local insert_info = get_normal_insert_info()
	utils.prompt_and_run(" Assist Insert ", function(input)
		run_assist_insert(insert_info, input)
	end)
end

return M
