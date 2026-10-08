defmodule WardrikNotify do
  @moduledoc """
  Tells people what agents are doing when nobody is watching: a turn that
  parked on a question, one that failed, and, when asked for, what a turn
  answered.

  `config.yaml` names targets, and an agent file routes its agent to them:

      notify:
        ops:
          slack:
            channel: "#ops"
            token: ${SLACK_BOT_TOKEN}
            app_token: ${SLACK_APP_TOKEN}
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
            secret: ${WARDRIK_WEBHOOK_SECRET}

      # agents/triage.md
      notify: {to: [ops], on: [parked, failed, finished]}

  A target is a module implementing this behaviour and its options.
  `WardrikNotify.Slack` and `WardrikNotify.Webhook` ship with the package, and a
  host names its own beside them, as it starts `WardrikNotify.Supervisor`:

      {WardrikNotify.Supervisor,
       targets: [
         ops: {WardrikNotify.Slack, channel: "#ops", token: "xoxb-…", app_token: "xapp-…"},
         pager: {MyApp.Pager, opts}
       ]}

  A target's `:orgs` is the orgs whose agents it tells, every org's unless it
  says.

  `WardrikNotify.Dispatcher` subscribes to each routed agent's events and sends
  each `WardrikNotify.Notice` from the node that holds the agent, so a cluster
  sends it once. A notice that cannot be delivered is logged; nothing retries
  it past the target's own retries.
  """

  alias WardrikNotify.Notice

  @typedoc "Targets by name: the module that delivers to each, and its options."
  @type targets() :: [{atom(), {module(), keyword()}}]

  @doc """
  Sends `notice` where `opts` say, called in a task of its own. `opts` are
  the target's, with `:target` added, the target's name, and `:req_options`,
  merged into every HTTP request it makes: the target's own where it sets
  them, and `WardrikNotify.Supervisor`'s otherwise.
  """
  @callback deliver(Notice.t(), keyword()) :: :ok | {:error, term()}

  @doc "The target named `name` among `targets`, which may be given as its name's string."
  @spec target(targets(), atom() | String.t()) :: {:ok, {module(), keyword()}} | :error
  def target(targets, name) when is_atom(name), do: Keyword.fetch(targets, name)

  def target(targets, name) when is_binary(name) do
    case Enum.find(targets, fn {key, _target} -> Atom.to_string(key) == name end) do
      {_key, target} -> {:ok, target}
      nil -> :error
    end
  end

  @doc "Whether the target `name` among `targets` tells the agents of `org`, as its `:orgs` says."
  @spec tells?(targets(), atom() | String.t(), String.t() | nil) :: boolean()
  def tells?(targets, name, org) do
    case target(targets, name) do
      {:ok, {_module, opts}} -> served?(Keyword.get(opts, :orgs, :all), org)
      :error -> false
    end
  end

  defp served?(:all, _org), do: true
  defp served?(orgs, org), do: org in orgs

  @doc """
  Routes each agent in `routes` to its targets, replacing every route set
  before. An agent left out is no longer routed. Does nothing where
  `WardrikNotify.Supervisor` is not running, which no route can then need.
  """
  @spec put_routes(%{Wardrik.AgentID.t() => WardrikNotify.Route.t()}) :: :ok
  def put_routes(routes) when is_map(routes) do
    if GenServer.whereis(WardrikNotify.Dispatcher),
      do: WardrikNotify.Dispatcher.put_routes(routes),
      else: :ok
  end
end
