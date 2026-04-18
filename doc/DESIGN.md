# Assist

assist.nvim enables inline prompting and interaction with AI agents without taking you out of neovim, so you can maintain a flow state in the editor.
Many AI agent tools like Claude Code, OpenAI codex, and Cursor operate by having a separate window for interfacing with an agent via natural language chat.
The trend of these tools is increasingly to move the focus to an agent first, editor second experience. This can lead to fatigue as the role of the developer increasingly transitions to one of a reviewer whose working understanding of the code becomes fuzzier as more changes go through the AI and less hands on time is spent in the codebase.

assist.nvim flips this notion by allowing agent calls to remain first and foremost in the editor.
The goal here is to extract most of the useful value that AI tools provide without requiring a separate chat interface that takes you out of the flow state in the editor.
This UX tweak enables users to stay present and hands on in the codebase, so they can still do the fun parts of coding, maintain their mental model of the code, and outsource the tedious bits.

This would cover common use cases such as:

- Prompting to create a small well defined function, class, or other such snippet at a particular section of the codebase
- Prompting the AI to edit a particular selection of code
- Multi-file or multi-region changes of medium complexity (small refactors that move functions or classes around and update their imports and references for instance)
- Adding test cases a particular function / feature in the code
- Asking a question about a particular section of the code
- Trigger a completion at your cursor location. Note that this one is not even supported out of the box with Claude Code or Codex CLI tools since they don't integrate natively with the editor, it's a special on demand feature enabled by this plugin.
- Document a particular function / class / snippet with a docstring or comments

Note that this plugin primarily tries to tackle workflows for small and medium size requests. A dedicated window for agentic CLI tools does still have its place for large sweeping changes that require some back and forth deliberation with an agent, but for small and medium requests that are well specified where the user can be confident in the agent's ability to one shot the request, there's no reason to go to another window when you can make the request in the editor.

As part of the design philosophy, assist works asynchronously in the background so that you can continue your work even as the agent is working.

## Comparison to Alternatives

[opencode.nvim](https://github.com/nickjvandyke/opencode.nvim)
[99](https://github.com/ThePrimeagen/99/tree/master)
[pi](https://shittycodingagent.ai/)

## Design

### Selection Edit

The workflow is as follows:

1. The developer is working on some code and wants the AI to edit some code block.
   Ex.

```python
def read_data(url: str) -> bs4.BeautifulSoup:
    """
    Read the html from the url and parse it into a bs4.BeautifulSoup object
    """
    ...
```

2. The user highlights the part of the code that they want edited and then runs the command `:AssistSelect`.
   - A prompt box will pop up so the user can provide additional context to implement the given feature.
   - Here you can also provide additional context like relevant files / directories
3. assist.nvim then asynchronously implements the relevant feature (in this case completing the function), so the user can continue working on other parts of the code.

4. Neovim sends a request payload including the following data:

- Highlighted text for replacement (also used as context for completion / implementation)
- The user prompt with more instructions for completion / implementation. This can include pointers to other files and other context
- Language
- File path
- Highlight Region (line numbers)

2. A local Claude Code process spawned via plenary.nvim takes the prompt and works on the completion / implementation (asynchronously).

```
claude --print --output-format json "Complete or implement the code for the following region: {...payload information}"
```

3. assist.nvim replaces the highlight region with the output from claude

### Multi-Edit

assist.nvim also supports larger changes that span multiple files.
The flow is similar, but the user triggers it from normal mode which pulls up the prompt dialog.
In this case, changes can be proposed to different regions of the project and multiple edits may be proposed.
The proposed changes populate a quickfix list, which the user can cycle through. Upon selecting a quickfix change entry, a diff view opens to display the change and prompts the user to accept or reject the change.
The user can also edit the change in the diff view before accepting to apply the change.

### Snippet Insertion

This feature works much like the Selection Edit workflow, but can be triggered from normal mode so that it inserts code at the cursor. As such it does not replace any existing text, but just generates a snippet in place.

### Test Generation

### Asking Questions

### Cursor Completion

### Documentation

### Extended Prompt Autocomplete Features

- File context autocomplete (when using @ symbol) similar to how claude code autocomplete works

* Attach prompt to a specific conversation
* Send prompt to a specific subagent
* Reference skills

## To Do

### Prompt Buffer

- [ ] Improve the buffer ergonomics (wrap text)

### Context

- [ ] File context autocomplete via `@` symbol in the prompt dialog
- [ ] Treesitter AST search
- [ ] Include line numbers / code region

### Claude

- [ ] Model selector
- [ ] Attach a prompt to a specific conversation (conversation continuity)
- [ ] Route a prompt to a specific subagent
- [ ] Skill references in the prompt

### Nice to have

- [ ] Multi-file mode: support accepting/rejecting all changes at once
- [ ] Show token usage / cost estimate after each run
- [ ] Configurable keybindings for accept/reject in diff view

### Features

- [ ] Ask a question about a particular region or file of code inline get the response back in an inline buffer
- [ ] Conversation / message history

## Notes

- Multi file edits are tricky to do async because you don't know if you will work on regions of the code that the agent will also touch.
  - To reconcile this, we may want to have it write to a separate worktree branch that can be merged in as a post hook
