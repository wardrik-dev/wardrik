---
title: Errands in a browser
description: An agent that runs errands on websites in a real browser, reading freely and asking before each click or keystroke.
sidebar:
  order: 4
---

An agent that runs errands on sites with no API, in a real browser (Playwright's MCP server). It
reads freely; every click and keystroke waits for your approval.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install);
- Node, for `npx`, and Chrome (`npx playwright install chrome`);
- somewhere to approve from: `wardrik approve`, the [terminal client](/build/tui/),
  [Slack](/channels/slack/), or the [Telegram bridge](/examples/telegram-assistant/).

## The files

### The browser

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

- `except` drops the tools that run JavaScript.
- `gated` makes every action on a page wait for a person.
- Reading and navigating aren't gated, so keep nothing in its files you'd mind a page learning.

Under systemd, name `npx` by its full path (`which npx`). Restart and check:

```sh
systemctl --user restart wardrik
wardrik doctor
```

### The agent

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

`timeout` and `max_iterations` give an errand room; the budget covers one errand.

## Try it

`httpbin.org/forms/post` is a practice form that posts nowhere:

```sh
wardrik reload
wardrik ask errands "Order a large pizza with bacon and onion on https://httpbin.org/forms/post, for delivery at 19:00, in the name of Jon."
```

The turn parks when it reaches the form:

```sh
wardrik parked
```

```
1 waiting:
  default/errands  call_b287...  browser/browser_fill_form  browser__browser_fill_form is gated, so it asks unless a rule allows it by name, and none does.
      after reading content from outside, which may be what asked for it
```

`wardrik approve errands`, and it moves to the next step, which waits in turn. Slack and the Telegram
bridge show each call's arguments.

## Letting it click

Once you trust it on a kind of errand, let it click and choose alone, and keep typing waiting:

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

`allow_after` keeps these allowed after reading a page. A click can buy something, so choose per
agent.

## What it shows

- **Content from outside.** See [Content from outside](/concepts/outside-content/).
- **Gated tools.** See [Gated tools](/concepts/rules/#gated-tools).
- **Narrowing a server.** See [Connect MCP servers](/build/mcp/#giving-an-agent-the-tools).
- **A parked turn never times out.** See [Approvals](/concepts/approvals/).

## Details

### Taking it further

- Give the [Telegram assistant](/examples/telegram-assistant/) `browser/*` and approve each step from
  your phone.
- `--isolated` keeps the browser profile in memory, so no session outlives the server.
- Pages it reads are saved to `.playwright-mcp/` in its working directory; `--output-dir` moves them.
