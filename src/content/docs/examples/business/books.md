---
title: The books agent
description: "Keeps the books in QuickBooks: small bills post on their own, big ones wait for an accountant, payroll is refused."
sidebar:
  order: 1
---

Each weekday morning this agent enters the bills that came in and reconciles yesterday's
transactions. A bill with every line under $1,000 posts on its own. A bigger one waits for an
accountant in Slack. Payroll is never touched.

Needs Intuit's [QuickBooks MCP server](https://github.com/intuit/quickbooks-online-mcp-server),
built on the daemon's machine, and a [Slack app](/channels/slack/).

## The files

```yaml title="~/.config/wardrik/config.yaml"
org: acme

mcp:
  quickbooks:
    command: node
    args: [/opt/quickbooks-online-mcp-server/dist/index.js]
    trusted: true
    env:
      QUICKBOOKS_CLIENT_ID: ${QUICKBOOKS_CLIENT_ID}
      QUICKBOOKS_CLIENT_SECRET: ${QUICKBOOKS_CLIENT_SECRET}
      QUICKBOOKS_REFRESH_TOKEN: ${QUICKBOOKS_REFRESH_TOKEN}
      QUICKBOOKS_REALM_ID: ${QUICKBOOKS_REALM_ID}
      QUICKBOOKS_ENVIRONMENT: production

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:acme/@maria, U0G9QF9C6: user:acme/@sam}

notify:
  targets:
    accounting: {channel: slack, room: "#accounting"}

roles:
  accountant:
    rules: [{verbs: [ask, read, events, decide], kinds: [agent], names: [books]}]
bindings:
  - {org: acme, role: accountant, subjects: [user:acme/@maria, user:acme/@sam]}
```

- `trusted: true` says the server's answers are your own books, not
  [content from outside](/concepts/outside-content/). Without it, every bill would wait.
- Maria and Sam are the accountants: they ask the agent and decide its calls.

```yaml title="~/.config/wardrik/policies/books.yaml"
allow:
  - quickbooks/search_*
  - quickbooks/get*
  - quickbooks/create-bill(params.bill.Line.Amount < 1000)
ask:
  quickbooks/create-bill(params.bill.Line.Amount >= 1000): A bill with a line of $1,000 or more.
  quickbooks/create_invoice: This creates a customer invoice.
deny:
  quickbooks/create-bill(params.bill.Line.AccountBasedExpenseLineDetail.AccountRef.value = 88): Payroll is off limits.
  quickbooks/create_bill_payment: Paying bills is for people.
budget: {usd: 10.00, per: day, on_exhausted: ask}
```

- An `allow` on a list holds only when every line matches. A `deny` holds when any line does.
- `88` stands for your Payroll account's ID in QuickBooks.

```markdown title="~/.config/wardrik/agents/books.md"
---
description: Keeps the books for the accounting team.
tools: [quickbooks/*, files]
context: [VENDORS.md]
channels: [slack]
policy: books
notify: {to: [accounting], on: [parked, failed, finished]}
triggers:
  - name: close
    every: "0 7 * * 1-5"
    prompt: Reconcile yesterday's transactions, and enter the bills that came in.
---
You keep Acme's books in QuickBooks. Enter each bill against the right vendor and expense account.
VENDORS.md says which account each vendor's bills go to; keep it current as the accountants correct
you. When you aren't sure, ask in one line. Each morning, post a short summary.
```

## Try it

```sh
echo "$QUICKBOOKS_CLIENT_ID" | wardrik vault put QUICKBOOKS_CLIENT_ID --for api_key
# ...and the other QuickBooks keys, the Slack token and signing secret
systemctl --user restart wardrik
wardrik ask books 'Enter the March invoice from Northwind Freight: $640 for deliveries.'
```

It finds the vendor and posts the bill. Ask for a $2,400 bill and it waits in `#accounting`, with
the bill's lines as its arguments.

## What it shows

- Argument rules on real data: amounts and accounts, read from the call. See
  [Policy](/concepts/policy/).
- A deny no message can get around.
- Approvals where the accountants work, each recorded with who decided.
- Corrections land in `VENDORS.md`, read into the next turn.
