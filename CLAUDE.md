# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Plugin Does

assist.nvim is a Neovim plugin for AI-powered code editing with two modes:

**Single-file (`:AssistPrompt`)**: The user highlights a code region and provides natural language instructions. Claude replaces the selection with an implementation. Claude runs as a sandboxed subprocess (`claude --print --output-format json`); because it has no write access, the result is extracted from `permission_denials[].tool_input` in the JSON response.

**Multi-file (`:AssistMulti`)**: The user describes a project-wide change from normal mode. Claude proposes Edit/Write tool calls across multiple files. These are captured from the `--output-format stream-json` response by parsing `tool_use` content blocks in `assistant` message events — no sandboxing needed. Proposed changes are presented in a quickfix list; pressing `<CR>` on an entry opens a vsplit diff in a new tab where the user can accept (`<leader>da`), reject (`<leader>dr`), or edit the proposed content before accepting.

## Development

No build step required — pure Lua. There are no tests, linters, or CI scripts.

To test manually, install the plugin in Neovim. For single-file mode: visually select lines and run `:AssistPrompt`. For multi-file mode: run `:AssistMulti` from normal mode, enter a prompt, then use `<CR>` in the quickfix list and `<leader>da`/`<leader>dr` in the diff tab. Check `/tmp/assist.log` for debug output (`utils.log()`).

## Architecture

```
plugin/assist.lua          Entry point — registers :AssistPrompt and :AssistMulti
lua/assist/init.lua        Single-file mode orchestration
lua/assist/multi.lua       Multi-file mode orchestration + session state
lua/assist/diff.lua        Diff tab lifecycle (open, accept, reject)
lua/assist/config.lua      Config defaults and setup()
lua/assist/context.lua     Treesitter + LSP context gathering (single-file only)
lua/assist/utils.lua       Buffer helpers + response parsing
```

### Single-file Data Flow (`:AssistPrompt`)

1. `:AssistPrompt` (visual range) → `assist_visual_selection(line1, line2)`
2. `prompt_and_run()` opens a centered modal for user input
3. `run_assist_selection()`:
   - Gathers treesitter/LSP context via `context.gather()`
   - Assembles XML-structured prompt via `build_prompt()`
   - Spawns `claude --output-format json` via `vim.fn.jobstart()`; shows extmark spinner
   - On exit: `parse_claude_response()` extracts result from `permission_denials[].tool_input`, `replace_lines()` updates the buffer

### Multi-file Data Flow (`:AssistMulti`)

1. `:AssistMulti` → `multi.assist_multi()` opens a centered modal
2. `run_multi()` spawns `claude --output-format stream-json`
3. On exit: `parse_tool_uses_from_stream()` collects all `tool_use` blocks from `assistant` events
4. `build_session()` resolves paths, snapshots original file contents, computes `proposed_full` for each change (chains multiple edits to the same file in order)
5. `populate_quickfix()` fills the qf list and installs a buffer-local `<CR>` handler
6. `on_qf_select()` → `diff.open_diff(change)` opens a vsplit diff in a new tab
7. `<leader>da` (accept): reads live proposed buffer, writes to disk, closes tab
8. `<leader>dr` (reject): closes tab, leaves file unchanged

### Key Module Responsibilities

**`multi.lua`** owns the `_session` table (list of change objects). Each change holds `path`, `tool_name`, `original_full` (snapshotted at job-fire time), `proposed_full`, and optionally `error`.

**`diff.lua`** owns `_diff_state` (single active diff). `close_diff()` calls `tabclose` — the scratch buffer's `bufhidden=wipe` cleans it up automatically.

**`utils.lua`** key functions:
- `parse_claude_response()` — single-file, extracts from `permission_denials`
- `parse_tool_uses_from_stream()` — multi-file, parses stream-json line by line
- `apply_edit_to_content()` — plain-string first-occurrence replace (matches Claude's Edit tool semantics)

**`context.lua`** gathers two types of context (single-file only):
- *Treesitter (sync)*: enclosing function/class scope + imports, language-specific via `SCOPE_TYPES`/`IMPORT_QUERIES` tables
- *LSP (async with 2000ms timeout)*: diagnostics + document symbols

**`config.lua`** defaults:
```lua
{
  claude_cmd = "claude",
  output_format = "json",
  context = { treesitter = true, lsp = true, lsp_timeout_ms = 2000 }
}
```

### Important Implementation Details

- **Spinner animation** uses `nvim_buf_set_extmark` with virtual lines. Positions re-queried via `nvim_buf_get_extmark_by_id` each tick to follow buffer changes.
- **Line indices**: user commands receive 1-indexed lines; `get_visual_selection()` converts to 0-indexed for `nvim_buf_*` APIs.
- **LSP response handling** must deal with both flat (`SymbolInformation[]`) and nested (`DocumentSymbol[]`) formats.
- **Multi-edit chaining**: when Claude proposes multiple edits to the same file, `build_session()` applies them sequentially — each edit operates on the result of the prior one (`proposed_by_path` table tracks this).
- **Diff tab cleanup**: `close_diff()` always calls `tabclose` on the diff tab, not `nvim_win_close` on individual windows, so the original file buffer is not disturbed.
