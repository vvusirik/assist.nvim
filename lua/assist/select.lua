local config = require("assist.config")
local utils = require("assist.utils")
local context = require("assist.context")

local M = {}

function M.setup(opts)
	config.setup(opts)
end

local function build_edit_prompt(selection, user_prompt, file_path, lang, ctx)
	local parts = {
		"<task>Complete or implement the following code region. You MUST apply your changes using the Edit tool — do not print the code as text.</task>",
		string.format(
			"<file path=%q language=%q start_line=%q end_line=%q/>",
			file_path,
			lang,
			tostring(selection.start_line + 1),
			tostring(selection.end_line + 1)
		),
		string.format("<selection>\n```%s\n%s\n```\n</selection>", lang, selection.text),
	}

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

local function run_assist_selection(selection, user_prompt)
	local buf = selection.buf
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local opts = config.options
	local ctx_cfg = opts.context or {}
	local select_cfg = opts.select or {}

	local spinner = utils.start_spinner(buf, {
		{ line = selection.start_line, above = true },
		{ line = selection.end_line },
	}, "Implementing...")

	local function start_job(ctx)
		local prompt = build_edit_prompt(selection, user_prompt, file_path, lang, ctx)
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

					local current_start = (positions[1] and positions[1][1]) or selection.start_line
					local current_end = (positions[2] and positions[2][1]) or selection.end_line
					-- Guard: if the region was fully deleted, treat as an insertion point
					if current_end < current_start then
						current_end = current_start
					end
					utils.replace_lines(buf, current_start, current_end, result)
					vim.notify("[assist.nvim] Done.", vim.log.levels.INFO)
				end)
			end,
		})

		if job_id <= 0 then
			spinner.stop()
			vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
			return
		end

		-- Close stdin so claude doesn't block waiting for input
		vim.fn.chanclose(job_id, "stdin")
	end

	local want_ts = select_cfg.include_ts_context ~= false and ctx_cfg.treesitter
	local want_lsp = select_cfg.include_lsp_context ~= false and ctx_cfg.lsp
	if want_ts or want_lsp then
		context.gather(buf, selection.start_line, selection.end_line, ctx_cfg.lsp_timeout_ms or 2000, function(ctx)
			if not want_ts then
				ctx.enclosing_scope = nil
				ctx.imports = nil
			end
			if not want_lsp then
				ctx.diagnostics = nil
				ctx.doc_symbols = nil
			end
			start_job(ctx)
		end)
	else
		start_job(nil)
	end
end

function M.assist_visual_selection(line1, line2)
	local selection = utils.get_visual_selection(line1, line2)
	if selection.text == "" then
		vim.notify("[assist.nvim] No text selected.", vim.log.levels.WARN)
		return
	end
	utils.prompt_and_run(" Assist Select ", function(input)
		run_assist_selection(selection, input)
	end)
end

return M
