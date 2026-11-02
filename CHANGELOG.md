# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `identities:`, required: a `WardrikChannel.Identities` that says who each chat member is in
  your app. A member it doesn't know can't ask or decide, and is told why.
- `WardrikChannel.Channel.owned/2`, the installations an owner holds, exactly.
- Options are validated with NimbleOptions, and documented from the schema. An adapter reads the
  ones left over from `:options`.

### Breaking

- Members act as the principal `identities:` gives, with the channel as their actor,
  `{:channel, name}`, and no grants: the host's authorizer decides from the scope's `context`,
  its `installation`, and when deciding, `asked_by`. A room offers the agents the authorizer lets
  the member read.
- No approvers or tenancy: the `approvers` option, `include?/2`, `WardrikChannel.Membership`,
  `Workspace.principal/2`, `Workspace.approver?/1`, `Outbound`'s `approvers`, and the `approver`
  context key are gone. `Workspace.member_scope/2` and `Workspace.deciding_scope/2` return
  `{:ok, scope}` or what to tell the member. The channel's own scope acts for the installation's
  owner.
- A notice posts in the workspace its `Wardrik.Channel.Notification` names, the one the agent's
  resolver gives, and is skipped if the channel isn't added there.
- `WardrikChannel` callbacks take what they act on, then the `WardrikChannel.Channel`:
  `deliver/2` the outbound, `install_url/2` and
  `installed/2` a `WardrikChannel.Install`, and `uninstall/2` the workspace. The installation
  stores implement `Wardrik.Channel.Installations` rc.2.
- An install's token is sealed as a `:token`, and read only as one.
- `WardrikChannel.Channel.new/2` raises `NimbleOptions.ValidationError` on an invalid option.
- Functions take named arguments: `WardrikChannel.decide/2` a `WardrikChannel.Answer`, as does
  `Workspace.deciding_scope/2`; `Workspace.conversation/2`, `Workspace.thread/2`,
  `Replies.remind/2`, `Rooms.start/2`, `Rooms.started?/2`, `Rooms.chose/2` and
  `Replies.State.arguments/2` a keyword list.

## 0.1.0-rc.1 (2026-10-30)

- Channels as adapters: `use WardrikChannel`, with `deliver/2`, `include?/4` and `children/1`.
- Rooms bound to the one agent offered, or one picked, answering mentions or every message, kept
  in Wardrik's store and recorded in its audit.
- Threads as conversations of the room's agent, asked as the person who wrote.
- Replies posted from the agents' logs by one process per room in the cluster, carrying on from
  where they were after a restart, and tried again when the chat app refuses them.
- Waiting calls posted with their arguments, decided by approvers or whoever asked.
- Installations: one from a `token:`, or your own for one app in many workspaces.
