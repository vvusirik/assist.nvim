local config = require("assist.config")
local utils = require("assist.utils")

local M = {}

function M.setup(opts)
	config.setup(opts)
end

local function build_prompt(selection, user_prompt, file_path, lang)
	return string.format(
		"Complete or implement the code for the following region.\n\n"
			.. "File: %s\n"
			.. "Language: %s\n"
			.. "Lines: %d-%d\n\n"
			.. "Code to replace:\n```%s\n%s\n```\n\n"
			.. "Additional instructions: %s\n\n"
			.. "Return ONLY replacement code with no surrounding explanations.",
		file_path,
		lang,
		selection.start_line + 1,
		selection.end_line + 1,
		lang,
		selection.text,
		user_prompt
	)
end

local function run_assist(selection, user_prompt)
	local buf = selection.buf
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local prompt = build_prompt(selection, user_prompt, file_path, lang)
	local opts = config.options

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

				utils.replace_lines(buf, selection.start_line, selection.end_line, result)
				vim.notify("[assist.nvim] Done.", vim.log.levels.INFO)
			end)
		end,
	})

	if job_id <= 0 then
		vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
		return
	end

	-- Close stdin so claude doesn't block waiting for input
	vim.fn.chanclose(job_id, "stdin")
end

local function prompt_and_run(selection)
	local width = 60
	local height = 8
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false

	local ui = vim.api.nvim_list_uis()[1]
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((ui.width - width) / 2),
		row = math.floor((ui.height - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Assist Prompt ",
		title_pos = "center",
	})

	vim.cmd("startinsert")

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local input = vim.trim(table.concat(lines, "\n"))
		close()
		if input == "" then
			return
		end
		vim.notify("[assist.nvim] Running claude...", vim.log.levels.INFO)
		run_assist(selection, input)
	end

	local map_opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "<CR>", submit, map_opts)
	vim.keymap.set("n", "q", close, map_opts)
	vim.keymap.set("n", "<Esc>", close, map_opts)
end

function M.assist_prompt()
	local selection = utils.get_visual_selection()
	if selection.text == "" then
		vim.notify("[assist.nvim] No text selected.", vim.log.levels.WARN)
		return
	end
	prompt_and_run(selection)
end

return M
