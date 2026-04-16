# Assist

## Overview

assist.nvim is a neovim plugin that enables inline prompting and interaction with AI agents

The workflow is as follows:

1. The developer is working on some code and wants the AI to finish some code block.
   Ex.

```python
def read_data(url: str) -> bs4.BeautifulSoup:
    """
    Read the html from the url and parse it into a bs4.BeautifulSoup object
    """
    ...
```

2. The user highlights the part of the code that they want replaced with implementation and then runs the command `:AssistPrompt`.
   - A prompt box will pop up so the user can provide additional context to implement the given feature.
   - Here you can also provide additional context like relevant files / directories
3. assist.nvim then asynchronously implements the relevant feature (in this case completing the function), so the user can continue working on other parts of the code.

## Design

assist integrates with claude code via a spawned subprocess.

1. Neovim sends a request payload including the following data:

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

### Extended Prompt Autocomplete Features

- File context autocomplete (when using @ symbol) similar to how claude code autocomplete works

* Attach prompt to a specific conversation
* Send prompt to a specific subagent
* Reference skills

## To Do
- [ ] File context autocomplete via `@` symbol in the prompt dialog
- [ ] Attach a prompt to a specific conversation (conversation continuity)
- [ ] Route a prompt to a specific subagent
- [ ] Skill references in the prompt
- [ ] Multi-file mode: support accepting/rejecting all changes at once
- [ ] Show token usage / cost estimate after each run
- [ ] Configurable keybindings for accept/reject in diff view
- [ ] Single-file mode: support non-visual (cursor-word or whole-buffer) selection

## Notes
