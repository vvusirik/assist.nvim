# Assist

**This plugin is a work in progress**

assist.nvim enables inline prompting and interaction with AI agents without taking you out of neovim, so you can maintain a flow state in the editor.
Many AI agent tools like Claude Code, OpenAI codex, and Cursor operate by having a separate window for interfacing with an agent via natural language chat.
The trend of these tools is increasingly to move the focus to an agent first, editor second experience. This can lead to fatigue as the role of the developer increasingly transitions to one of a reviewer whose working understanding of the code becomes fuzzier as more changes go through the AI and less hands on time is spent in the codebase.

assist.nvim flips this notion by allowing agent calls to remain first and foremost in the editor.
The goal here is to extract most of the useful value that AI tools provide without requiring a separate chat interface that takes you out of the flow state in the editor.
As part of the design philosophy, assist works asynchronously so that you can continue your work even as the agent is working.
These subtle UX tweaks enable users to stay present and hands on in the codebase, so they can still do the fun parts of coding and maintain their mental model of the code while outsourcing the tedious bits.

This would cover common use cases such as:

- **Insert** - prompt a snippet to generate at the cursor location
- **Edit** - visual select a code block and prompt a change to the code region
- **Multi-file edits** - describe a project-wide change and review proposed changesets in a diff view (through quickfix list)
- **Add tests** - generate test cases for a function or feature inline
- **Ask** - ask a question about a selected code region and receive the response inline
- **Completion** - trigger an on-demand completion at your cursor, without leaving the editor
- **Document** - generate a docstring or comments for a function, class, or snippet

This plugin focuses on small-to-medium, well-specified requests that an agent can one-shot. 
For large, open-ended changes requiring back-and-forth deliberation, a dedicated agentic CLI window is still the right tool.
