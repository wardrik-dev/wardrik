---
title: "Policies"
description: "A policy written as data: the tools an agent may call, the ones that ask a person first, and the ones it may not call at all."
editUrl: false
sidebar:
  order: 4
---

<!-- Written by mix wardrik.docs from WardrikPolicy. Edit it there, not here. -->

A policy written as data: the tools an agent may call, the ones that ask a
person first, and the ones it may not call at all.

    policy =
      WardrikPolicy.decode!(%{
        "allow" => ["web_search", "linear/*"],
        "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
        "deny" => ["run_lua"],
        "default" => "allow"
      })

    Wardrik.Fleet.spawn(id, config: config, hooks: WardrikPolicy.hooks(policy))

A policy's rules are a `Wardrik.Hook`, named for the policy. It is plain data,
so it is written to the store with the agent it governs and decides the
same way on whichever node holds that agent.

## Budgets

A policy with a `WardrikPolicy.Budget` limits what the agent spends on model
calls. `hooks/1` gives the budget a hook of its own, after the rules, named
for the policy with `/budget` added.

## Deciding

Every rule whose `WardrikPolicy.Pattern` names a call speaks for it, and the
strictest of them decides: `:deny` over `:ask` over `:allow`. A call no rule
names is decided by `:default`, which is `:allow` unless set. A rule's
message is what a person is asked, or what the model is told it may not do.
The rules allow every model call.

A rule may name what a call acts on, `write_file(notes/*)`, and speaks then
for each of the call's subjects it matches (see `c:Wardrik.Tool.subjects/2`).
A deny or an ask that speaks for any subject decides the call, and the call
is allowed by the rules only where they allow the whole of it, or every one
of its subjects; otherwise `:default` decides:

    allow: [shell(git status), shell(git diff *)]
    deny: [shell(git push *)]

## Allowing by name

A call an `allow` rule allows is allowed by name, with an
`:allow` decision, which is what a gated tool's call waits for (see
`Wardrik.Tool.Annotations`). One allowed only by `default: allow` is not, so
a gated tool asks under a policy that names nothing, as it does under none.

## After what the run has read

A run carries the `Wardrik.Label`s of what it has read. Once it carries
`"outside"`, content nobody on the agent's side wrote, a gated tool's call
waits on a person however the rules allowed it, since what the run read
may be what asked for it. An `allow_after` rule allows by name as `allow`
does, and holds after its label too: it is for a tool whose calls may
follow what a stranger wrote, because the agent reaches nothing they could
take, or the tool can do little harm.

    allow: [linear/*]
    allow_after:
      outside: [github/add_labels]

A label the policy names under `allow_after` holds a gated tool's calls the
same way, and the call is allowed only where, for every such label the run
carries, `allow_after` rules for it allow the whole of the call, or every
one of its subjects. A label the policy does not name is carried and
shown, and holds nothing.

## Written down

`decode/1` reads the map form a file or a request writes a policy in, and
`encode/1` writes it back:

    allow: [web_search, linear/*]
    ask:
      github/create_*: This opens an issue on GitHub.
    deny: [run_lua]
    default: allow

`allow`, `ask` and `deny` each take a list of patterns, or a map of pattern
to message, and `allow_after` a map of label to either. `budget` takes what
`WardrikPolicy.Budget` describes.
