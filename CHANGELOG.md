# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `WardrikSlack.schema/0`: the options it takes beyond `WardrikChannel`'s, checked as the channel
  starts and documented from the schema.

### Breaking

- People in Slack act with the channel as their actor, and Wardrik's authorizer decides what
  they may do, in place of the grants the channel gave them.
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
