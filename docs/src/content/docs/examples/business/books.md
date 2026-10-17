---
title: The books agent
description: "Keeps the books in QuickBooks: small bills post on their own, big ones wait for an accountant, payroll is refused."
sidebar:
  order: 1
---

This agent does the bookkeeping a small business falls behind on. Each weekday morning it
reconciles yesterday's transactions, enters the bills that came in, and asks in Slack about anything
it isn't sure of. Small bills post on their own. Bills over $1,000 wait for an accountant. Payroll
is never touched.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- QuickBooks Online, and Intuit's official
  [QuickBooks MCP server](https://github.com/intuit/quickbooks-online-mcp-server), built on the
  daemon's machine;
- a [Slack app](/channels/slack/#a-slack-app) and a channel for the accountants, here `#accounting`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme

mcp:
  quickbooks:
    command: node
    args: [/opt/quickbooks-online-mcp-server/dist/index.js]
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

notify:
  accounting:
    channel: slack
    room: "#accounting"
    approvers: ["@maria", "@sam"]
```

- The server runs on the daemon's machine and talks to QuickBooks with your app's keys. Its
  `npm run auth` gets the refresh token once.
- `approvers` are the accountants, who may press Approve and Deny.

Seal the keys and restart:

```sh
wardrik vault put QUICKBOOKS_CLIENT_ID      # and the secret, refresh token and realm id
systemctl --user restart wardrik
wardrik doctor
```

### The policy

QuickBooks' tools take their arguments inside `params`, so the rules name the real paths:

```yaml title="~/.config/wardrik/policies/books.yaml"
allow:
  - quickbooks/search_*
  - quickbooks/get*
  - quickbooks/read_*
  - quickbooks/create-bill(params.bill.Line.Amount < 1000)
ask:
  quickbooks/create-bill(params.bill.Line.Amount >= 1000): A bill with a line over $1,000.
  quickbooks/create_invoice: This creates a customer invoice.
  quickbooks/create_payment: This records a customer's payment.
deny:
  quickbooks/create-bill(params.bill.Line.AccountBasedExpenseLineDetail.AccountRef.value = 88): Payroll is off limits.
  quickbooks/create_bill_payment: Paying bills is for people.
budget:
  usd: 10.00
  per: day
  on_exhausted: ask
```

- **Small bills post.** A bill posts on its own when every line is under $1,000. A rule on a list
  holds for every item: see [Writing rules](/concepts/rules/#what-a-calls-arguments-are).
- **Big ones wait.** Any line at $1,000 or more waits for an accountant.
- **Payroll is refused.** `88` stands for your Payroll account's Id in QuickBooks. A deny holds if
  any line names it, however the agent was asked.
- **Money out is for people.** Paying a bill is refused outright.

### The agent

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
    every: "0 7 * * 1-5"          # 07:00 UTC on weekdays
    prompt: Reconcile yesterday's transactions, and enter the bills that came in.
---
You keep Acme's books in QuickBooks. Enter each bill against the right vendor and expense account;
VENDORS.md says which account each vendor's bills go to. When you aren't sure, ask in one line and
wait for the answer.

Each morning, post a short summary: what you entered, what's waiting for approval, and anything
that doesn't reconcile.
```

- `context` reads `VENDORS.md` into every turn: the agent's own notes on where each vendor's bills
  go, which it keeps as the accountants correct it.
- `channels` lets the accountants answer its questions in a Slack thread.

## Try it

```sh
wardrik reload
wardrik ask books "Enter the March invoice from Northwind Freight: $640 for deliveries."
```

It looks up the vendor, enters the bill, and posts it, since every line is under $1,000. Ask for a
$2,400 bill and it waits in `#accounting` instead, with the bill's lines as its arguments.

## What it shows

- **Argument rules on real data.** Limits on amounts and accounts, read from the call itself.
- **A deny that holds.** No message, however phrased, gets a payroll bill posted.
- **Approvals where accountants work**, with every decision and who made it recorded.
- **Memory that improves.** Corrections land in `VENDORS.md` for the next bill.

## Details

### What a line rule means

The rule is on each line, not the bill's total: a bill of three $900 lines posts on its own. To cap
totals too, ask for every bill and review what posted each week.

### Xero

Xero's [official server](https://github.com/XeroAPI/xero-mcp-server) runs with
`npx -y @xeroapi/xero-mcp-server@latest`. A bill there is an invoice of type `ACCPAY`, so the rules
read:

```yaml
allow:
  - xero/list-*
  - xero/create-invoice(type = ACCPAY, lineItems.unitAmount < 1000)
ask:
  xero/create-invoice: This enters an invoice or a bill.
```

### Intuit's hosted server

Intuit also runs a hosted QuickBooks server, by invitation only. It has invoice and sales tools but
no bill tools, so this example uses the local one.

### Taking it further

- Add Square to reconcile sales: allow
  `square/make_api_request(service = payments, method = list)` and nothing that writes.
- Give the agent `web_search` to look up a vendor it hasn't seen.
