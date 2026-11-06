# Changelog

## Unreleased

- A member carries the email address Slack holds for them, unless they're from another
  workspace. The app asks for the `users:read.email` scope again; reinstall it to grant it.
- A button press looks up who pressed it with `users.info`, as a message does.
- Requires the unreleased `wardrik_channel`.

## 0.1.0-rc.3 (2026-11-04)

- A notice for a turn in one of the workspace's threads isn't posted: the thread already shows
  the turn's answer, approvals and failure. The skip is logged with its reason.
- Requires `wardrik_channel` 0.1.0-rc.3.

## 0.1.0-rc.2 (2026-11-02)

- `WardrikSlack.schema/0`: the options it takes beyond `WardrikChannel`'s, checked as the channel
  starts and documented from the schema.

### Breaking

- Each thread is its own conversation of the room's agent. `WardrikSlack.Messages.event/3`
  returns `{:asked, {agent, conversation}}`.
- A waiting call's buttons hold the agent and the conversation apart. Buttons posted by rc.1 are
  ignored.
- Slack members act as the users `identities:` gives. Your authorizer decides what they may do,
  including who may approve.
- No approvers: `WardrikSlack.Approvers`, `include?/2`, direct messages to approvers, and the
  `users:read.email` scope are gone. A waiting call is asked in its thread.
  `WardrikSlack.Waiting.message/1` and `WardrikSlack.Notices.message/1` take only the calls or
  notice.
- `WardrikSlack.Rooms.shown/1` shows an offer's display name, or else its agent's ID.
- A notice posts in the workspace the agent's resolver gives.
- Implements the rc.2 `WardrikChannel` and `Wardrik.Channel` callbacks.
- `WardrikSlack.API.post/2` and `read/2` take the method, then `:token`, `:body` or `:params`, and
  `:req_options`. `WardrikSlack.Blocks.button/2` takes the label, then `:action_id`, `:value` and
  `:style`.

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
