# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `WardrikSlack.schema/0`: the options it takes beyond `WardrikChannel`'s, checked as the channel
  starts and documented from the schema.

### Breaking

- A thread is a conversation of the room's agent, passed to Wardrik as `conversation`.
  `WardrikSlack.Messages.event/3` returns `{:asked, {agent, conversation}}`.
- A waiting call's buttons hold the agent (`g`) and the conversation (`c`) apart. Buttons posted
  by rc.1 are ignored.
- People in Slack act as the users the channel's `identities:` gives, with the channel as their
  actor, and Wardrik's authorizer decides what they may do, deciding calls included, in place of
  the grants the channel gave them.
- It speaks only Slack's protocol. No approvers: `WardrikSlack.Approvers`, `include?/2`, direct
  messages to approvers and their `users.info`, `users.list` and `users.lookupByEmail` lookups,
  and the `users:read.email` scope are gone. A waiting call is asked in its thread for whoever
  may decide it. `WardrikSlack.Waiting.message/1` and `WardrikSlack.Notices.message/1` take no
  approvers. `WardrikSlack.Rooms.shown/1` shows an offer's display name, or else its agent's ID.
- A notice posts in the workspace its notification names.
- Implements `WardrikChannel` and `Wardrik.Channel` rc.2's callbacks, each taking what it acts on,
  then the channel or its options.
- `WardrikSlack.API.post/2` and `read/2` take the method, then `:token`, `:body` or `:params`, and
  `:req_options` by name. `WardrikSlack.Blocks.button/2` takes the label, then `:action_id`,
  `:value` and `:style`.

## 0.1.0-rc.1 (2026-10-30)

- A `WardrikChannel` adapter for a Slack app: agents answer mentions in threads, and replies in
  them, as the person who wrote.
- Events and buttons over HTTP, signed with the app's signing secret, or over Socket Mode with an
  app-level token, for testing with no public address.
- Rooms bound as the app is invited, with buttons to answer every message, switch agents, or stop.
- Waiting calls posted with their arguments, a note box, and Approve and Deny, or Show link for a
  sign-in. Approvers named by handle, email or member ID are each asked in the app's Messages tab,
  with a link to the thread, which says who it waits on. Where none can be reached, the thread asks.
- :eyes: on what an agent takes, :white_check_mark: once it's answered, and the agent's status in
  its thread while it works.
- One app in many workspaces, added through Slack's OAuth with `WardrikSlack.Install`.
