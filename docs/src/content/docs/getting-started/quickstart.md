---
title: Quickstart
description: "Run an agent, review its proposed file write, and approve the call."
---

Create an agent that saves a note. Review the proposed file write before allowing it to run.

## 1. Install and configure Wardrik

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/download/wardrik_daemon-v0.1.0-rc.12/install.sh | sh
wardrik init
```

Choose a model provider and enter your API key. `init` creates the configuration and starts the daemon.
For Docker or non-interactive setup, see [Install](/getting-started/install/).

## 2. Create an agent

Save this file as `~/.config/wardrik/agents/notes.md`:

```markdown title="~/.config/wardrik/agents/notes.md"
---
description: Saves notes for the team.
tools: [files]
policy:
  ask:
    write_file: Review the note before saving it.
---
Save notes when asked. Use the requested filename and text.
```

The filename sets the agent’s name: `notes`. The YAML configures its tools and permissions;
the Markdown body provides its instructions. It uses the model selected during setup.

## 3. Request a note

```sh
wardrik reload
wardrik ask notes "Write HELLO.md with the text: Hello from Wardrik."
```

Wardrik shows the proposed `write_file` call and prompts for approval. Review the filename and
text, then type `y` to save the note. Press Enter to leave the call pending.

To approve later, list pending calls and copy the call ID:

```sh
wardrik approval ls
wardrik approval approve notes CALL_ID
```

To reject a pending call instead:

```sh
wardrik approval deny notes CALL_ID --reason "Use a different filename."
```

The agent receives the reason and can propose a revised call.

## 4. Read the saved note

```sh
wardrik ask notes "Read HELLO.md and show its contents."
```

The reply includes `Hello from Wardrik.` The file is saved in the agent’s persistent workspace,
which is separate from your local filesystem.

## Next steps

- [Add a TypeScript tool](/build/first-tool/) to call your application code.
- [Connect MCP servers](/build/mcp/) to use existing integrations.
- [Use the assistant](/build/assistant/) to create agents through requests and approvals.
- [Browse examples](/examples/) for support, incident response, and personal automation.
