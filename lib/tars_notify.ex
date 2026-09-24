defmodule TarsNotify do
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
            url: https://hooks.example.com/tars
            secret: ${TARS_WEBHOOK_SECRET}

      # agents/triage.md
      notify: {to: [ops], on: [parked, failed, finished]}

  A target is a module implementing this behaviour and its options.
  `TarsNotify.Slack` and `TarsNotify.Webhook` ship with the package, and a
  host names its own as `config :tars, TarsNotify, targets: [pager:
  {MyApp.Pager, opts}]`.

  `TarsNotify.Dispatcher` subscribes to each routed agent's events and sends
  each `TarsNotify.Notice` from the node that holds the agent, so a cluster
  sends it once. A notice that cannot be delivered is logged; nothing retries
  it past the target's own retries.
  """

  alias TarsNotify.Notice

  @doc """
  Sends `notice` where `opts` say, called in a task of its own. `opts` are
  the target's, with `:target` added: the target's name.
  """
  @callback deliver(Notice.t(), keyword()) :: :ok | {:error, term()}

  @doc "Whether any target is configured."
  @spec configured?() :: boolean()
  def configured?, do: TarsNotify.Config.targets() != []

  @doc """
  Routes each agent in `routes` to its targets, replacing every route set
  before. An agent left out is no longer routed. Does nothing where
  `TarsNotify.Supervisor` is not running, which no route can then need.
  """
  @spec put_routes(%{String.t() => TarsNotify.Route.t()}) :: :ok
  def put_routes(routes) when is_map(routes) do
    if GenServer.whereis(TarsNotify.Dispatcher),
      do: TarsNotify.Dispatcher.put_routes(routes),
      else: :ok
  end
end
