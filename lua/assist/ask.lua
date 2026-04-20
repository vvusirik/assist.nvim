local config = require("assist.config")
local utils = require("assist.utils")

local M = {}

function M.setup(opts)
	config.setup(opts)
end

local function build_ask_prompt_selection(selection, user_prompt, file_path, lang, buf_content)
	local parts = {
		"<task>Concisely answer the question about the code region in markdown format. "
			.. "Use your tools to read and explore files you need for more context.</task>",
		string.format(
			"<file path=%q language=%q start_line=%q end_line=%q/>",
			file_path,
			lang,
			tostring(selection.start_line + 1),
			tostring(selection.end_line + 1)
		),
	}
	if buf_content then
		table.insert(parts, string.format("<file_content>\n```%s\n%s\n```\n</file_content>", lang, buf_content))
	end
	table.insert(parts, string.format("<selection>\n```%s\n%s\n```\n</selection>", lang, selection.text))
	table.insert(parts, string.format("<question>%s</question>", user_prompt))

	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function build_ask_prompt_normal(user_prompt, file_path, lang)
	local parts = {
		"<task>Concisely answer the question in markdown format. "
			.. "Use your tools to read and explore files you need for more context.</task>",
		string.format("<file path=%q language=%q />", file_path, lang),
	}
	table.insert(parts, string.format("<question>%s</question>", user_prompt))

	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function run_assist_ask(selection, user_prompt)
	local buf = nil
	local spinner = nil
	if selection ~= nil then
		buf = selection.buf
		spinner = utils.start_spinner(buf, {
			{ line = selection.start_line, above = true },
			{ line = selection.end_line },
		}, "Thinking...")
	else
		local normal_info = utils.get_normal_insert_info()
		buf = normal_info.buf
	end

	local file_path = vim.api.nvim_buf_get_name(buf)
	local opts = config.options

	local lang = vim.bo[buf].filetype
	local buf_content = nil
	if vim.bo[buf].modified then
		buf_content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end

	local prompt = nil
	if selection ~= nil then
		prompt = build_ask_prompt_selection(selection, user_prompt, file_path, lang, buf_content)
	else
		prompt = build_ask_prompt_normal(user_prompt, file_path, lang)
	end
	local stdout_lines = {}
	local stderr_lines = {}

	local cmd = {
		opts.claude_cmd,
		"--disallowedTools",
		"Edit",
		"Write",
		"--print",
		"--verbose",
		"--output-format",
		"stream-json",
		"--model",
		opts.model,
		prompt,
	}
	utils.log("=== AssistAsk command: " .. table.concat(cmd, " "))

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
				if spinner ~= nil then
					spinner.stop()
				end

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
				local result, err = utils.parse_result_text(raw)
				if err then
					vim.notify("[assist.nvim] " .. err, vim.log.levels.ERROR)
					return
				end
				assert(result ~= nil)
				local answer_buf = vim.api.nvim_create_buf(false, true)
				vim.bo[answer_buf].bufhidden = "wipe"
				vim.api.nvim_buf_set_lines(answer_buf, 0, -1, false, vim.split(result, "\n", { plain = true }))
				vim.bo[answer_buf].modifiable = false

				vim.cmd("botright 15split")
				local win = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(win, answer_buf)
				vim.bo[answer_buf].filetype = "markdown"
				vim.wo[win].wrap = true
				vim.wo[win].linebreak = true
				vim.wo[win].number = false
				vim.wo[win].signcolumn = "no"

				local map_opts = { noremap = true, silent = true, buffer = answer_buf }
				vim.keymap.set("n", "q", function()
					vim.api.nvim_win_close(win, true)
				end, map_opts)
				vim.keymap.set("n", "<Esc>", function()
					vim.api.nvim_win_close(win, true)
				end, map_opts)
			end)
		end,
	})

	if job_id <= 0 then
		if spinner then
			spinner.stop()
		end
		vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
		return
	end

	vim.fn.chanclose(job_id, "stdin")
end

function M.assist_ask_selection(line1, line2)
	local selection = utils.get_visual_selection(line1, line2)
	utils.prompt_and_run(" Assist Ask ", function(input)
		run_assist_ask(selection, input)
	end)
end

function M.assist_ask_normal()
	utils.prompt_and_run(" Assist Ask ", function(input)
		run_assist_ask(nil, input)
	end)
end

function M.assist_explain(line1, line2)
	local selection = utils.get_visual_selection(line1, line2)
	run_assist_ask(selection, "Explain this section.")
end

return M
