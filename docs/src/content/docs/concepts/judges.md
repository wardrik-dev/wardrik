---
title: Judged calls
description: "A judge asks a model yes-or-no questions about each call, and decides by the probability of yes."
sidebar:
  order: 7
---

Some decisions turn on what a call means, not its name: does it change the books, does it send
money out? A `judge` asks a model yes-or-no questions about each call and acts on the probability.

```yaml title="~/.config/wardrik/policies/books.yaml"
ask: [books/delete_*]
judge:
  model: typesafe:jev-latest
  questions:
    - question: Does this call record, change or delete anything in the company's books?
      tools: [books/*]
      ask: 0.5
      allow: 0.05
    - question: Does this call send money to a person or an account outside the company?
      ask: 0.5
      deny: 0.9
      message: Money leaves the company only with a person's say-so.
```

| Key | When the probability is | The call |
| --- | --- | --- |
| `deny` | at or above it | is refused |
| `ask` | at or above it | waits for a person, who sees the question and the probability |
| `allow` | below it | is allowed by name |

Between the thresholds, the rules decide alone. The judge runs after the rules, so its allow never
lifts a rule's ask or deny.

:::caution
A judge is a second opinion beside the rules, not a replacement.

- **Its allow only holds before the run reads outside content.** Arguments can be written to fool it.
- **Calibrate it first.** Start with `ask` and `deny`, watch it on real calls, then add a low
  `allow`.
- **One thing per question.** Write two questions, not one with "and".
- **Exact matters go in rules.** A tool's name or a file's path is a rule's job.
:::

Try a judge on calls agents already made with `wardrik policy judge`; see
[Tuning a judge](#tuning-a-judge).

## Tuning a judge

Uncertain calls land mid-range. Asked "Does this call send money outside the company?", one model
scored listing unpaid invoices 0.04, creating a $1,200 bill 0.52, and paying that bill 0.72, short of
a `deny` at 0.8.

- **For critical tools, widen the band a person sees.** Set `ask` at 0.3 or below and `deny` high.
  Better, name the tool in a rule, `ask: [bank/send_*]`, and let the judge catch what names miss.
- **Leave a margin under `allow`.** If harmless calls score 0.04 and risky ones 0.3, an `allow` of
  0.01–0.02 is safer than 0.05.
- **Say what counts.** The judge sees the question, the tool's name and its arguments, nothing else.
  "Does this call pay money out of the company's accounts now? Recording a bill does not count." took
  the bill from 0.52 to 0.05 and the payment to 0.77.
- **Name the tools.** A question without `tools` is asked of every call, adding a request to each.
- **Watch for a judge that can't answer:** a run of asks saying so.
- **Retest when the model changes.** A `latest` model can move.

`wardrik policy judge NAME` asks the judge again about calls agents made, without changing anything.
It reads the policy file as it is now, so you can adjust before `wardrik reload`, and marks with `!`
each call it would decide differently:

```text
$ wardrik policy judge books
books's judge on 2 calls of the agents under books, newest first; 1 decided otherwise than it would.

! books/send_payment  acme/books  2026-10-09 14:02:11Z
    arguments  {"amount":1200,"to":"Northwind"}
    0.72       Does this call send money to a person or an account outside the company?
    judge      asks a person
    decided    allowed by books
```

It tries the agents whose definitions name the policy, or those under `--agent` (an agent, or an
org as `acme/`), so you can test a judge before any agent uses it. `--last N` sets how many calls,
20 by default; `--json` gives the full answers. Only calls that ran are tried, and the log doesn't
record whether a run had read outside content, so an allow is shown as for a run that hadn't.

## Details

### How a judge decides

The questions whose `tools` name a call, or all questions without `tools`, are asked together in one
request, with the tool's name and arguments. The call is allowed only if every question with an
`allow` is below its own. A refusal gives `message`, or the question, as the reason. A judge that
can't answer, because its model is unreachable or replies with nothing usable, asks a person if any
of its questions could ask or deny; otherwise it stays silent. `model` defaults to
`typesafe:jev-latest`; seal its key as any model key: `wardrik vault put TYPESAFE_API_KEY`.
