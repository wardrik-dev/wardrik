defmodule WardrikChannel do
  @moduledoc """
  A chat medium Wardrik's agents are reached through, such as Slack: the
  behaviour each one's adapter implements, and how the adapters a release
  holds are found.

  A *channel* is one configured instance of an adapter, under a name of the
  deployment's own: one Slack workspace's app, say, with its tokens. A *room*
  is a place in it, such as a Slack channel.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}
        globex-slack:
          type: slack
          org: globex
          token: ${GLOBEX_SLACK_BOT_TOKEN}

  ## Adapters

  An adapter is a module implementing this behaviour, in a package of its
  own. It names itself in its application's environment, under
  `:wardrik_channels`, so whatever starts channels finds it by its type
  without naming it:

      # mix.exs of wardrik_slack
      def application,
        do: [env: [wardrik_channels: [slack: WardrikSlack]]]

  `adapters/0` lists the types the loaded applications name, and `adapter/1`
  finds one.

  ## What an adapter does

    * `config/1` reads a channel's settings, as `config.yaml` writes them
      with `type` and `org` taken out, and answers the options its other
      callbacks take, or where they do not read.
    * `child_spec/1` is what a channel runs, such as its connection to the
      medium, started by `WardrikChannel.Supervisor` with the channel's
      options, its `:name`, and its `WardrikChannel.Context`.
    * `deliver/2` posts a `WardrikChannel.Outbound` in a room.

  ## Rooms

  An adapter tells `WardrikChannel.Rooms` when its bot is invited into a
  room or taken out of one, and what was chosen there, handing it the
  channel's context. See `WardrikChannel.Rooms` for how a room comes to have
  an agent.

  `WardrikChannel.Notices` is a `WardrikNotify` target that posts notices in
  a room through a channel's adapter.
  """

  alias WardrikChannel.Outbound

  @typedoc "A channel: its adapter, and the options its `config/1` answered."
  @type channel() :: {module(), keyword()}

  @doc """
  Reads a channel's settings, as `config.yaml` writes them, less `type` and
  `org`. Answers the options its callbacks take, or the key that does not
  read, as a path within the channel, and why.
  """
  @callback config(settings :: map()) :: {:ok, keyword()} | {:error, [String.t()], String.t()}

  @doc "What the channel runs, given its options, its `:name` and its `:context`."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Posts `outbound` in its room, as the channel whose options these are."
  @callback deliver(Outbound.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Every adapter the loaded applications name, by its type."
  @spec adapters() :: %{String.t() => module()}
  def adapters do
    for {app, _description, _version} <- Application.loaded_applications(),
        {type, module} <- Application.get_env(app, :wardrik_channels, []),
        into: %{},
        do: {to_string(type), module}
  end

  @doc "The adapter of `type`, where a loaded application names one."
  @spec adapter(String.t()) :: {:ok, module()} | :error
  def adapter(type) when is_binary(type), do: Map.fetch(adapters(), type)

  @doc "The task supervisor a channel runs its work under."
  @spec tasks() :: atom()
  def tasks, do: WardrikChannel.TaskSupervisor
end
