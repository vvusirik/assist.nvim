# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Plugin Does

assist.nvim is a Neovim plugin for AI-powered code editing with two modes:

**Single-file (`:AssistPrompt`)**: The user highlights a code region and provides natural language instructions. Claude replaces the selection with an implementation. The command runs `claude --disallowedTools "Write Edit" --print --verbose --output-format stream-json <prompt>`; the replacement is extracted from the `tool_use` content block emitted in the assistant message (before the permission check runs). `--disallowedTools` ensures the `Write`/`Edit` tool never actually executes, so the behavior is independent of the user's global permission policy.

**Single-file (`:AssistInsert`)**: Normal-mode variant. The user places the cursor on a line and describes a snippet to insert. Same transport as `:AssistPrompt`, but the generated content is spliced in *after* the cursor line instead of replacing a range.

**Multi-file (`:AssistMulti`)**: The user describes a project-wide change from normal mode. Claude is prompted to respond with a bare JSON array of `{file_path, start_line, end_line, new_content}` line-number edits as its final text (no tool-use payload). The array is parsed from `envelope.result` of the `--output-format json` response. Proposed changes are presented in a quickfix list; pressing `<CR>` on an entry opens a vsplit diff in a new tab where the user can accept (`<leader>da`), reject (`<leader>dr`), or edit the proposed content before accepting.

## Development

No build step required — pure Lua. There are no tests, linters, or CI scripts.

To test manually, install the plugin in Neovim. For single-file mode: visually select lines and run `:AssistPrompt`. For multi-file mode: run `:AssistMulti` from normal mode, enter a prompt, then use `<CR>` in the quickfix list and `<leader>da`/`<leader>dr` in the diff tab. Check `/tmp/assist.log` for debug output (`utils.log()`).

## Architecture

```
plugin/assist.lua          Entry point — registers :AssistPrompt, :AssistInsert, :AssistMulti
lua/assist/select.lua      :AssistPrompt (visual-range replace) orchestration
lua/assist/insert.lua      :AssistInsert (normal-mode insert) orchestration
lua/assist/multi.lua       :AssistMulti multi-file orchestration + session state
lua/assist/diff.lua        Diff tab lifecycle (open, accept, reject)
lua/assist/config.lua      Config defaults and setup()
lua/assist/context.lua     Treesitter + LSP context gathering (currently unused; kept for future reuse)
lua/assist/utils.lua       Buffer helpers + spinner + response parsing
```

### Single-file Data Flow (`:AssistPrompt` / `:AssistInsert`)

1. User enters a prompt via `utils.prompt_and_run()` modal.
2. `run_assist_selection()` (or `run_assist_insert()`) builds an XML-structured prompt that includes the selection or surrounding-cursor lines and instructs Claude to emit its answer via the `Write` (insert) or `Edit` (select) tool.
3. `utils.start_spinner()` places animated virtual lines around the affected region; `vim.fn.jobstart()` runs `claude --disallowedTools "Write Edit" --print --verbose --output-format stream-json <prompt>`.
4. On exit: `utils.parse_edit_write_tool_response()` walks the newline-delimited stream events, finds the first `Write`/`Edit` `tool_use` block inside an `assistant` event, and returns `input.content` / `input.new_string`. The content is then spliced into the buffer via `nvim_buf_set_lines` (insert appends after the tracked cursor mark; select replaces the tracked `[start, end]` range).

### Multi-file Data Flow (`:AssistMulti`)

1. `:AssistMulti` → `multi.assist_multi()` opens a centered modal
2. `run_multi()` spawns `claude --print --output-format json` with a prompt instructing Claude to emit a bare JSON array of line-number edits as its final text
3. On exit: `utils.parse_line_edits()` decodes `envelope.result`, stripping an optional markdown fence, and validates each entry has `file_path`, `start_line`, `end_line`, `new_content`
4. `build_session()` groups edits by file, sorts each file's edits by `start_line`, snapshots original file contents, and applies edits sequentially via `utils.apply_line_edit()` — tracking a line-count offset so later edits' line numbers stay correct after earlier ones expand/contract the file
5. `populate_quickfix()` fills the qf list and installs a buffer-local `<CR>` handler
6. `on_qf_select()` → `diff.open_diff(change)` opens a vsplit diff in a new tab
7. `<leader>da` (accept): reads live proposed buffer, writes to disk, closes tab
8. `<leader>dr` (reject): closes tab, leaves file unchanged

### Key Module Responsibilities

**`multi.lua`** owns the `_session` table (list of change objects). Each change holds `path`, `original_full` (snapshotted at job-fire time), `proposed_full`, `start_line`, `end_line`, `new_content`, `is_new_file`, and optionally `error`.

**`diff.lua`** owns `_diff_state` (single active diff). `close_diff()` calls `tabclose` — the scratch buffer's `bufhidden=wipe` cleans it up automatically.

**`utils.lua`** key functions:
- `parse_edit_write_tool_response()` — single-file, walks stream-json events and returns the first `Write`/`Edit` tool_use's content string
- `parse_line_edits()` — multi-file, decodes `envelope.result` as a JSON array of line-number edits (tolerates a wrapping markdown fence)
- `apply_line_edit()` — splices `new_content` into a full-file string over the 1-indexed inclusive `[start_line, end_line]` range
- `start_spinner()` — shared spinner helper used by `insert.lua` and `select.lua`; returns a handle with `stop()` and `positions()`

**`context.lua`** (currently unused, kept for possible reuse) gathers two types of context:
- *Treesitter (sync)*: enclosing function/class scope + imports, language-specific via `SCOPE_TYPES`/`IMPORT_QUERIES` tables
- *LSP (async with 2000ms timeout)*: diagnostics + document symbols

**`config.lua`** defaults:
```lua
{
  claude_cmd = "claude",
  prompt_buf = { width = 60, height = 8 },
  insert = { context_lines = 20 },
}
```
The `--output-format` is hard-coded per flow (`stream-json` for single-file, `json` for multi) because each flow's parser is format-specific.

### Important Implementation Details

- **Spinner animation** uses `nvim_buf_set_extmark` with virtual lines. Positions re-queried via `nvim_buf_get_extmark_by_id` each tick to follow buffer changes.
- **Line indices**: user commands receive 1-indexed lines; `get_visual_selection()` converts to 0-indexed for `nvim_buf_*` APIs.
- **LSP response handling** must deal with both flat (`SymbolInformation[]`) and nested (`DocumentSymbol[]`) formats.
- **Multi-edit chaining**: when Claude proposes multiple edits to the same file, `build_session()` sorts them by `start_line` and applies them sequentially. An `offset` counter tracks the cumulative line-count delta so each subsequent edit's 1-indexed line numbers are adjusted against the evolving file, not the original.
- **Diff tab cleanup**: `close_diff()` always calls `tabclose` on the diff tab, not `nvim_win_close` on individual windows, so the original file buffer is not disturbed.
