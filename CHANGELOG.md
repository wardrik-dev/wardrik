# Changelog

## 0.1.0-rc.3 (2026-11-04)

- An adapter's `deliver/2` may return `{:skip, why}` to decline a post, such as a notice for a
  turn its thread already shows. A thread reply it declines isn't tried again.
- `WardrikChannel.Workspace.thread?/2` returns whether a conversation is a thread in one of the
  workspace's rooms.

## 0.1.0-rc.2 (2026-11-02)

- `identities:`, required: a `WardrikChannel.Identities` that says who each chat member is in your
  app. A member it doesn't know can't ask or decide, and is told why.
- `WardrikChannel.Channel.owned/2` lists the installations an owner holds.
- Options are validated with NimbleOptions. `WardrikChannel.Channel.new/2` raises
  `NimbleOptions.ValidationError` on an invalid one. An adapter reads the rest from `:options`.
- Requires `wardrik_protocol`, `wardrik_events` and `wardrik_vault` 0.1.0-rc.2.

### Breaking

- Each thread is its own conversation of the room's agent, such as
  `"slack.T0123.C024BE91L.1696.1234"` from `Workspace.conversation/2`.
  `WardrikChannel.received/2` returns `{:asked, {agent, conversation}}`.
- `WardrikChannel.Waiting` and `WardrikChannel.Answer` have `:agent` and `:conversation`.
- Replies follow each thread's conversation only. `Workspace.logs/2` is gone. `Replies.follow/2`
  and `Replies.remind/2` take `:room`, `:agent` and `:conversation`. Saved replies start over.
- Your authorizer decides what members may do. Their scope has `actor: {:channel, name}`, and
  `:installation` and `:asked_by` in its `context`. A room offers the agents a member may read.
- Removed: the `approvers` option, the `include?/4` callback, `WardrikChannel.Membership`,
  `Workspace.principal/2` and `Workspace.approver?/1`.
- `Workspace.member_scope/2` and `Workspace.deciding_scope/2` return `{:ok, scope}`, or what to
  tell the member.
- A notice posts in the workspace the agent's resolver gives, and is skipped if the channel isn't
  added there.
- Callbacks take what they act on, then the channel: `deliver/2`, `install_url/2`, `installed/2`
  (with a `WardrikChannel.Install`) and `uninstall/2`.
- An install's token is sealed in the vault as a `:token`.
- Functions take named arguments: `WardrikChannel.decide/2` and `Workspace.deciding_scope/2` a
  `WardrikChannel.Answer`; `Workspace.conversation/2`, `Workspace.thread/2`, `Replies.remind/2`,
  `Rooms.start/2`, `Rooms.started?/2` and `Rooms.chose/2` a keyword list.

## 0.1.0-rc.1 (2026-10-30)

- Channels as adapters: `use WardrikChannel`, with `deliver/2`, `include?/4` and `children/1`.
- Rooms bound to the one agent offered, or one picked, answering mentions or every message, kept
  in Wardrik's store and recorded in its audit.
- Threads as conversations of the room's agent, asked as the person who wrote.
- Replies posted from the agents' logs by one process per room in the cluster, carrying on from
  where they were after a restart, and tried again when the chat app refuses them.
- Waiting calls posted with their arguments, decided by approvers or whoever asked.
- Installations: one from a `token:`, or your own for one app in many workspaces.
