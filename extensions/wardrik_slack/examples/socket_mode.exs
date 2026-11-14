# Runs an agent in your Slack workspace over Socket Mode, with no public address.
#
#   SLACK_BOT_TOKEN=xoxb-... SLACK_APP_TOKEN=xapp-... ANTHROPIC_API_KEY=sk-ant-... \
#     mix run --no-halt examples/socket_mode.exs
#
# Optional: WARDRIK_ORG (acme), WARDRIK_MODEL.

defmodule Local.Clock do
  @behaviour Wardrik.Capability

  @impl true
  def tools(_context, _opts) do
    [
      Wardrik.Tool.new!(
        name: "clock",
        description: "Tells the time on the server, in UTC.",
        schema: [],
        run: fn _args, _context -> {:ok, DateTime.utc_now() |> DateTime.to_iso8601()} end
      )
    ]
  end
end

defmodule Local.Authorizer do
  @behaviour Wardrik.Authorizer

  # Everyone here may do anything, but in Slack only whoever asked decides.
  @impl true
  def authorize(%{actor: {:channel, _name}, action: "agent.decide"} = request, _opts) do
    if request.context[:asked_by] == request.principal.id, do: :ok, else: {:error, :forbidden}
  end

  def authorize(_request, _opts), do: :ok
end

defmodule Local.Agents do
  @behaviour Wardrik.Resolver

  # Every agent acts for the org.
  @impl true
  def resolve(_request, org), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal(org)}}
end

defmodule Local.Members do
  @behaviour Wardrik.Chat.Identities

  # Each Slack member is a user of their own. Your app maps them to its users.
  @impl true
  def identify(%Wardrik.Chat.Identities.Request{workspace: workspace, member: member}, _opts),
    do: {:ok, Wardrik.principal("slack:#{workspace}/#{member}")}
end

defmodule Local.Wardrik do
  use Wardrik
end

Logger.configure(level: :warning)

org = System.get_env("WARDRIK_ORG", "acme")

{:ok, wardrik} =
  Local.Wardrik.start_link(
    authorizer: {Local.Authorizer, []},
    resolver: {Local.Agents, org},
    capabilities: [clock: Local.Clock],
    policies: [careful: [ask: ["clock"]]],
    channels: [
      slack:
        {WardrikSlack,
         token: System.fetch_env!("SLACK_BOT_TOKEN"),
         app_token: System.fetch_env!("SLACK_APP_TOKEN"),
         owner: org,
         identities: {Local.Members, []}}
    ]
  )

Process.unlink(wardrik)

me = Local.Wardrik.as(org)

{:ok, agent} =
  Wardrik.Agent.define(me, "agt_assistant",
    model: System.get_env("WARDRIK_MODEL", "anthropic:claude-haiku-4-5"),
    instructions: "You help people in Slack. Keep answers short. Use the clock to tell the time.",
    description: "Answers questions, and asks before it reads the clock.",
    tools: ["clock"],
    policy: "careful",
    channels: ["slack"]
  )

IO.puts("""
#{agent.id} is offered in Slack. Invite your app into a Slack channel with /invite @YourApp,
then mention it: "@YourApp what time is it?" Approve the clock in the thread.
""")
