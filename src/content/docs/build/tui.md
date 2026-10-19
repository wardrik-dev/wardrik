---
title: The terminal client
description: "Watch and talk to agents, and decide what they wait on, in a terminal client the daemon serves over SSH."
sidebar:
  order: 8
---

The daemon serves a terminal client over SSH: the transcript of the agent you're attached to, a
panel of every agent, and a prompt. It shows each turn as it happens, wherever the agent runs.

## Let yourself in

List your key, then attach:

```sh
mkdir -p ~/.config/wardrik/ssh
cat ~/.ssh/id_ed25519.pub >> ~/.config/wardrik/ssh/authorized_keys
wardrik attach
```

`wardrik attach` is `ssh -p 2222` to localhost. For a daemon on another machine, forward the port
first:

```sh
ssh -N -L 2222:localhost:2222 box &
wardrik attach
```

A listed key reaches every agent and can do anything the client does, including removing agents.
It isn't limited the way a [token](/run/tokens/) is.

## Use it

Type at the prompt and press Enter to send a message. Quitting ends your session only; agents carry
on.

| Key | |
| --- | --- |
| Ctrl-P | the command palette |
| Ctrl-Y, Ctrl-N | approve or deny the call waiting |
| Ctrl-F | show or hide the fleet panel |
| Ctrl-X, then `h` `j` `k` `l` | move between the transcript, the panel and the prompt |
| Ctrl-X, then `s` | stop the turn |
| `i` | back to the prompt |
| Up, Down | earlier lines at the prompt |
| Ctrl-T | show the turn as a trace |
| `/`, `n`, `N` | search the transcript |
| `t` | a tool call's arguments and output in full |
| `y` | copy |
| Ctrl-D | quit, from an empty prompt |

## Commands

| Command | |
| --- | --- |
| `/spawn NAME [node=N] [--bg] [-- prompt]` | start an agent and attach to it |
| `/connect [NAME]` | attach to an agent, or pick one from a list |
| `/next` | attach to the next agent waiting on a person |
| `/approve [N \| all] [note]` | approve the waiting call, one by number, or all, with a note |
| `/deny [N \| all] [reason]` | deny it, saying why |
| `/stop [NAME \| PATTERN]` | stop this agent's turn, another's, or every agent's a pattern such as `acme/agent/*` covers |
| `/move [NAME [node=N]]` | start an agent again on another node, as it was |
| `/shutdown NAME` | stop an agent and keep its conversation; `/spawn` brings it back |
| `/rm NAME \| PATTERN` | remove an agent and its conversation, or every agent a pattern covers, after showing what goes |
| `/fleet`, `/filter [QUERY]` | the fleet panel, narrowed as `wardrik ls` narrows |
| `/find [TEXT]` | search the transcript |
| `/tools` | a tool call of this conversation in full |
| `/copy [code]` | copy the last answer, or its last code block |
| `/help` | every key and command, searchable |

## Details

- The client is served once `~/.config/wardrik/ssh/authorized_keys` lists a key, in OpenSSH's format.
  It's read at every login, so changes count from the next connection.
- A key connects under the name its comment gives before any `@`, as `jon@laptop` gives `jon`, or
  under the names its `principals` option lists, and no other. Each connection is its own session:

  ```
  principals="jon,ana" ssh-ed25519 AAAAC3Nza... shared@desk
  ```

- The daemon listens on port 2222, on loopback. `ssh` in `config.yaml` sets `port`, and `ip` to
  listen beyond loopback. Its host key is made on first start, under `~/.local/share/wardrik/ssh`.
- In Docker, mount a directory holding `ssh/authorized_keys` at `/config`, and publish port 2222.
- A session opens on the first agent by key, or starts your own, `@<you>/assistant` in the
  deployment's org. That assistant, and each agent `/spawn` starts, gets `config.yaml`'s `defaults`.
- A bare `y` or `n` at the prompt answers a waiting call too.
- The client is drawn from the [event stream](/concepts/events/).
- Copying uses the terminal's clipboard escape, OSC 52, so it reaches the clipboard of the machine
  you typed `ssh` on, where the terminal supports it.
