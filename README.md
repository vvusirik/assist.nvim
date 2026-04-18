# Assist

**This plugin is a work in progress**

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

