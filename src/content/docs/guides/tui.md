---
title: The terminal client
description: Watch and talk to agents, and decide what they wait on, in a terminal client the daemon serves over SSH.
sidebar:
  order: 7
---

The daemon serves a terminal client over SSH: a transcript of the agent you are attached to, a
panel of every agent in the fleet, and a prompt. It is drawn from the
[event stream](/concepts/events/), so it shows a turn as it happens, wherever in the cluster the
agent runs.

## Letting yourself in

The client is served once `~/.config/wardrik/ssh/authorized_keys` lists a key, in OpenSSH's format:

```sh
mkdir -p ~/.config/wardrik/ssh
cat ~/.ssh/id_ed25519.pub >> ~/.config/wardrik/ssh/authorized_keys
wardrik attach
```

`wardrik attach` is `ssh -p 2222` to localhost. A client holding a listed key connects under any user
name, and each connection is a session of its own. The file is read at every login, so a key added
or removed counts from the next connection.

A key listed there reaches every agent and may do anything the client does, including starting and
removing agents. It is not limited the way a [token](/operate/security/#tokens) is.

The daemon listens on port 2222, on loopback. `ssh` in `config.yaml` sets `port`, and `ip` to listen
beyond loopback. Its host key is made on first start, under `~/.local/share/wardrik/ssh`.

### A daemon on another machine

Forward the port through SSH to the machine, and attach to it:

```sh
ssh -N -L 2222:localhost:2222 box &
wardrik attach
```

In Docker, mount a directory holding `ssh/authorized_keys` at `/config`, and publish port 2222.

## Using it

A session opens on the first agent, by key, or starts your own, `@<you>/assistant` in the
deployment's org, where none runs. Type at
the prompt and press Enter to send a message. Quitting ends the session and nothing else: the agents
carry on.

| Key | |
| --- | --- |
| Ctrl-P | the command palette |
| Ctrl-F | show or hide the fleet panel |
| Ctrl-X, then `h` `j` `k` `l` | move between the transcript, the panel and the prompt |
| Ctrl-X, then `s` | stop the turn |
| `i` | back to the prompt |
| Up, Down | earlier lines at the prompt |
| Ctrl-Y, Ctrl-N | approve or deny the call waiting |
| Ctrl-T | show the turn as a trace |
| `/`, `n`, `N` | search the transcript |
| `t` | a tool call's arguments and output in full |
| `y` | copy |
| Ctrl-D | quit, from an empty prompt |

A bare `y` or `n` at the prompt answers a waiting call too.

## Commands

| Command | |
| --- | --- |
| `/spawn NAME [node=N] [--bg] [-- prompt]` | start an agent and attach to it |
| `/connect [NAME]` | attach to an agent, or pick one from a list |
| `/next` | attach to the next agent waiting on a person |
| `/approve [N \| all]` | approve the waiting call, one by number, or all |
| `/deny [N \| all] [reason]` | deny it, saying why |
| `/stop [NAME \| PREFIX/]` | stop this agent's turn, another's, or every agent's under a prefix |
| `/move [NAME [node=N]]` | start an agent again on another node, as it was |
| `/shutdown NAME` | stop an agent and keep its conversation; `/spawn` brings it back |
| `/rm NAME \| PREFIX/` | remove an agent and its conversation, after showing what goes |
| `/fleet`, `/filter [QUERY]` | the fleet panel, narrowed as `wardrik ls` narrows |
| `/find [TEXT]` | search the transcript |
| `/tools` | a tool call of this conversation in full |
| `/copy [code]` | copy the last answer, or its last code block |
| `/help` | every key and command, searchable |

Over SSH, copying uses the terminal's clipboard escape, OSC 52, so it reaches the clipboard of the
machine you typed `ssh` on, where the terminal supports it.
