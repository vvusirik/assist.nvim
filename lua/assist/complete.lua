local config = require("assist.config")
local utils = require("assist.utils")

local M = {}

local function build_complete_prompt(context, file_path, lang)
	local parts = {
		"<task>Provide a code completion suggestion given the context code up to the completion boundary. You MUST suggest your changes using the Edit tool — do not print the code as text.</task>",
		string.format(
			"<file path=%q language=%q line=%q col=%q/>",
			file_path,
			lang,
			tostring(context.cursor_row + 1),
			tostring(context.cursor_col + 1)
		),
		string.format("<context>\n```%s\n%s\n```\n</context>", lang, context.text),
	}
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function run_assist_completion()
	local buf = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local opts = config.options

	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]

	local lines = vim.api.nvim_buf_get_lines(0, 0, row + 1, false)
	lines[#lines] = lines[#lines]:sub(1, col)
	local text = table.concat(lines, "\n")
	local context = {
		text = text,
		cursor_row = row,
		cursor_col = col,
	}

	local spinner = utils.start_spinner(buf, { { line = row - 1, above = true } }, "Completing...")

	local prompt = build_complete_prompt(context, file_path, lang)
	local stdout_lines = {}
	local stderr_lines = {}

	local cmd = {
		opts.claude_cmd,
		"--disallowedTools",
		"Write",
		"--print",
		"--verbose",
		"--output-format",
		"stream-json",
		prompt,
	}
	local job_id = vim.fn.jobstart(cmd, {
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
				local result, err = utils.parse_edit_write_tool_response(raw)
				if err then
					vim.notify("[assist.nvim] " .. err, vim.log.levels.ERROR)
					return
				end
				if result == nil then
					vim.notify("[assist.nvim] got nil result from claude call", vim.log.levels.ERROR)
				end

				local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local buf_content = table.concat(buf_lines, "\n")
				local new_content, n = buf_content:gsub(vim.pesc(result.old_string), result.content, 1)
				if n == 0 then
					vim.notify("[assist.nvim] Could not find anchor text in buffer", vim.log.levels.ERROR)
					return
				end
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new_content, "\n", { plain = true }))
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

function M.assist_insert_completion()
	run_assist_completion()
end

return M
