---
title: The books agent
description: "Bookkeeping in QuickBooks. Small bills post automatically, large ones need an accountant's approval, payroll is denied."
sidebar:
  order: 1
---

Each weekday morning this agent enters new bills and reconciles yesterday's transactions. A bill
with every line under $1,000 posts without approval. Larger bills need an accountant's approval in
Slack. Payroll calls are denied.

Requires Intuit's [QuickBooks MCP server](https://github.com/intuit/quickbooks-online-mcp-server),
built on the daemon's machine, and a [Slack app](/build/slack/).

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
    domains: {acme.com: acme}

notify:
  targets:
    accounting: {channel: slack, room: "#accounting"}

roles:
  accountant:
    rules: [{verbs: [ask, read, events, decide], kinds: [agent], names: [books]}]
bindings:
  - {org: acme, role: accountant, subjects: [user:acme/@maria, user:acme/@sam]}
```

- `trusted: true` marks the server's results as trusted, not
  [content from outside](/concepts/outside-content/). Without it, every bill would need approval.
- The `accountant` role allows `@maria` and `@sam` to message the agent and approve its calls.

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

- On a list argument, `allow` matches only when every item matches. `deny` matches when any does.
- `88` is a placeholder for your Payroll account ID in QuickBooks.

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

It looks up the vendor and posts the bill. A $2,400 bill is posted to `#accounting` for approval,
with the bill's lines as arguments.

## What it shows

- Policy rules on call arguments: amounts and account IDs. See [Policy](/concepts/policy/).
- A `deny` that no prompt can bypass.
- Approvals in Slack, each recorded with the approver.
- Corrections are written to `VENDORS.md` and loaded into the next turn.
