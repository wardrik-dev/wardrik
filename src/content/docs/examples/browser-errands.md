---
title: Errands in a browser
description: An agent that runs errands on websites in a real browser, reading pages freely and asking you before each click or keystroke, with the arguments in front of you.
sidebar:
  order: 4
---

An agent with a browser: it fills in forms, books, checks in and looks things up on sites that have
no API. It reads pages as it likes, and every click, keystroke and form it would submit waits for
you to approve it, with what it would do in front of you. Once you have watched it work, you can
let it click on its own and keep only what it types waiting on you.

The browser is Playwright's MCP server, which the daemon runs as a command.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#1-install) gives it one;
- Node, for `npx`, and Chrome, which `npx playwright install chrome` installs where it is not
  already;
- somewhere to approve from: `wardrik approve` in a shell, the
  [terminal client](/build/tui/), Slack with [buttons](/channels/slack/), or the
  [Telegram bridge](/examples/telegram-assistant/).

## The browser

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  browser:
    command: npx
    args: [-y, "@playwright/mcp@0.0.83", --headless]
    except: [browser_evaluate, browser_run_code_unsafe]
    gated:
      - browser_click
      - browser_type
      - browser_fill_form
      - browser_select_option
      - browser_press_key
      - browser_file_upload
      - browser_drag
      - browser_drop
      - browser_handle_dialog
```

- `except` leaves out the two tools that run JavaScript in the page, so the agent works the page
  as a person would.
- `gated` lists every tool that does something on a page. A call to one waits on a person unless a
  rule allows it by name, and once the agent has read a page, which is content from outside, it
  waits however the rules allow it.
- Reading, `browser_snapshot`, `browser_find` and the rest, is not gated, and neither is
  `browser_navigate`: the agent goes where it decides to. A page could steer where that is, so give
  this agent nothing in its files that you would mind a page learning.

The service runs with systemd's `PATH`, which may not hold `npx`: name it by its full path, as
`which npx` gives it. Restart the daemon and check the server:

```sh
systemctl --user restart wardrik
wardrik doctor
```

## The agent

```markdown title="~/.config/wardrik/agents/errands.md"
---
description: Runs errands in a browser, asking before it does anything on a page.
model: anthropic:claude-sonnet-5
tools: [browser/*, files]
context: [ERRANDS.md]
timeout: 1800
max_iterations: 80
policy:
  budget: {usd: 3.00, per: turn, on_exhausted: ask}
---
You run errands on websites for one person, in a browser.

Read a page with browser_snapshot rather than a screenshot. Fill a form with browser_fill_form, in
one call, so the person approves it once. Before anything that pays, books or sends, stop and say
what it will do and what it costs, and wait to be told to go on.

ERRANDS.md is what you know about them and the sites they use. Keep it current. When an errand is
done, say what you did and what came of it.
```

`timeout` and `max_iterations` give a turn room for the many rounds an errand takes, and the budget
is for one errand at a time. Read the agent files again, and send it on one:

```sh
wardrik reload
wardrik ask errands "Order a large pizza with bacon and onion on https://httpbin.org/forms/post, for delivery at 19:00, in the name of Jon."
```

`httpbin.org/forms/post` is a practice form, which posts nothing anywhere. The turn parks as it
reaches the form:

```sh
wardrik parked
```

```
1 waiting:
  default/errands  call_b287...  browser/browser_fill_form  browser__browser_fill_form is gated, so it asks unless a rule allows it by name, and none does.
      after reading content from outside, which may be what asked for it
```

`wardrik approve errands` asks which call to approve, and the agent carries on to the next thing it
would do, which waits in turn. `wardrik parked` leaves out a call's arguments; a `notify` route to
Slack, or the Telegram bridge pointed at this agent, shows each call with them: the fields it would
fill and with what, the button it would press.

## Letting it click

Once you trust its judgement on a kind of errand, let it click and choose on its own, and keep what
it types waiting on you. Its policy allows those tools after it has read a page:

```yaml
policy:
  allow_after:
    outside:
      - browser/browser_click
      - browser/browser_select_option
      - browser/browser_press_key
  ask:
    browser/browser_fill_form: This fills in a form.
    browser/browser_type: This types into the page.
  budget: {usd: 3.00, per: turn, on_exhausted: ask}
```

`allow_after` allows a gated tool by name, as `allow` does, and keeps allowing it after the agent
has read content labelled `outside`, where `allow` stops counting. It is this agent's: another
agent given the same browser still asks before each click. The gated tools it does not name keep
waiting on a person, and `ask` gives the ones that type questions of their own.

A page is anyone's writing, and a click can buy something, so this is a choice about this agent's
errands. With `--isolated` the browser holds none of your sessions, which leaves a page less to
steer a click towards.

## What it shows

- **Content from outside.** Whatever a page says, a gated call after reading it waits on a person,
  who sees the call it is. See [Content from outside](/concepts/outside-content/).
- **Gated tools.** `gated` in `config.yaml` makes a server's tools wait unless a rule allows them
  by name, so a policy written later with `default: allow` cannot let them through. See
  [Gated tools](/concepts/rules/#gated-tools).
- **Narrowing a server.** `except` leaves tools out altogether, by the names the server gives them.
  See [Connect MCP servers](/build/mcp/#giving-an-agent-the-tools).
- **A parked turn waits.** It does not time out, and an agent's `timeout` starts again when it
  carries on, so an errand can wait for you through a meeting. See
  [Waiting on a person](/concepts/approvals/).

## Taking it further

- Give the [assistant in Telegram](/examples/telegram-assistant/) the browser, by adding
  `browser/*` to its tools, and approve each step from your phone.
- `--isolated` keeps the browser's profile in memory, so no cookie outlives the server; without it,
  a site you are signed in to stays signed in.
- The server writes each page it reads to `.playwright-mcp/` in its working directory, the daemon's
  unless `cwd` says another; `--output-dir` puts them elsewhere.
