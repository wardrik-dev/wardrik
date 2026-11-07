# WardrikDaemon

Run Wardrik agents from Markdown files, configure the daemon with YAML, and send messages through the CLI or HTTP API.

## Install

Requires Linux x86_64 or aarch64 with glibc 2.35+.

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.9/install.sh | WARDRIK_VERSION=0.1.0-rc.9 sh
wardrik init --org acme
wardrik ask assistant "Summarize this note: The release is scheduled for Friday."
```

- `init` prompts for a model provider, model, and API key.
- Select Anthropic to run the agent-file example below.
- It creates configuration files under `~/.config/wardrik` and starts the daemon.
- Existing files are preserved. On systemd, the daemon runs as a user service.
- Provider calls may incur charges. The assistant can propose worker agents and triggers; these changes require approval.

For noninteractive setup, set `MY_KEY` to your provider's API key:

```sh
wardrik init --provider anthropic --model claude-haiku-4-5 --key-from-env MY_KEY --no-service --no-ask
```

See [installation](https://docs.wardrik.dev/getting-started/install/) for containers, prerequisites, and service setup.

## Define an agent

Save this as `~/.config/wardrik/agents/triage.md`:

```markdown
---
model: anthropic:claude-haiku-4-5
---
Summarize incident reports. Include the impact and duration.
```

```sh
wardrik reload
wardrik ask triage "The API returned errors for five minutes. About 200 requests failed."
```

- The file name identifies the agent within its org.
- Agent files override `config.yaml` defaults.
- The daemon assigns an ID to each agent. HTTP requests use IDs; CLI commands accept names.
- Set `--conversation ID` to select a conversation.

See [agent files](https://docs.wardrik.dev/reference/agent-files/) for fields and tool configuration.

## Commands

```sh
wardrik ls
wardrik approval ls
wardrik doctor
wardrik help
wardrik help ask
```

Commands accept `--json`. See the [CLI reference](https://docs.wardrik.dev/reference/cli/).

## Configuration and operation

- [Configuration reference](https://docs.wardrik.dev/reference/config/)
- [Policies](https://docs.wardrik.dev/reference/policies/)
- [Storage](https://docs.wardrik.dev/run/storage/)
- [Clusters](https://docs.wardrik.dev/run/cluster/)
- [Organizations](https://docs.wardrik.dev/run/orgs/)
- [Security](https://docs.wardrik.dev/run/security/)
- [HTTP API](https://docs.wardrik.dev/reference/http-api/)
- [Troubleshooting](https://docs.wardrik.dev/run/troubleshooting/)

## Development

From this repository's checkout, with Elixir 1.20 and OTP 28:

```sh
mix deps.get
mix wardrik help
mix release
```

Use `mix wardrik` for CLI commands from source.
