defmodule Wardrik.Notify do
  @schema NimbleOptions.new!(
            targets: [
              type:
                {:list, {:tuple, [{:or, [:atom, :string]}, {:tuple, [:atom, :keyword_list]}]}},
              default: [],
              doc: """
              Targets by name, as `{module, opts}`. A target's `:orgs` limits it to those orgs'
              agents. Routing another org's agent to it is refused.
              """
            ],
            retries: [
              type: :keyword_list,
              default: [attempts: 3, max_wait: 10_000],
              doc: """
              How failed deliveries are retried. See `WardrikCore.Retry`. After that, the notice
              is logged and dropped.
              """
            ]
          )

  @moduledoc """
  Tells people when an agent parks, fails or finishes while nobody is watching.

  Name your targets in Wardrik's `:notify` option:

      notify: [
        targets: [
          audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: secret},
          ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}
        ]
      ]

  An agent's definition routes its notices with `notify`:

      # A target
      notify: "ops"

      # A room in one of Wardrik's channels
      notify: "slack:#updates"

      # Several
      notify: ["ops", "slack:#updates"]

      # Which kinds of `Wardrik.Notice` to send. `["parked", "failed"]` unless set.
      notify: %{to: ["ops"], on: ["finished"]}

  Conversations aren't routed anywhere.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Delivery

  One process in the cluster follows every agent's log. Each notice is sent at least once: after
  a restart it picks up where it left off. Tell repeats apart by agent, kind and `at`.
  """

  alias Wardrik.Error
  alias Wardrik.Notice
  alias Wardrik.Orgs

  @passed [wardrik: [type: :atom], target: [type: :string], orgs: [type: {:list, :string}]]

  @typedoc "Where an agent's notices go (`:to`), and which kinds are sent (`:on`)."
  @type route() :: %{to: [String.t()], on: [Notice.kind()]}

  @doc """
  Sends `notice`. Returns `{:skip, why}` if it shouldn't be sent, or `{:error, reason}` to retry.

  `opts` are the target's own, plus `:wardrik`, the instance, and `:target`, the target's name.
  """
  @callback deliver(Notice.t(), opts :: keyword()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc """
  Returns `opts` checked against a target's `schema`, or `{:skip, why}`.

  The schema needn't name `:wardrik`, `:target` or `:orgs`, which Wardrik passes every target.
  """
  @spec options(keyword(), keyword()) :: {:ok, keyword()} | {:skip, String.t()}
  def options(opts, schema) do
    case NimbleOptions.validate(opts, schema ++ @passed) do
      {:ok, opts} -> {:ok, opts}
      {:error, error} -> {:skip, "but its options are invalid: #{Exception.message(error)}"}
    end
  end

  @doc "Returns the `:notify` option's targets by name, and its retries."
  @spec settings(keyword() | nil) :: %{
          targets: %{String.t() => {module(), keyword()}},
          retries: keyword()
        }
  def settings(nil), do: settings([])

  def settings(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %{
      targets: Map.new(opts[:targets], fn {name, target} -> {to_string(name), target} end),
      retries: opts[:retries]
    }
  end

  @doc """
  Returns the route in `definition`'s `notify`, or `nil`.

      Wardrik.Notify.route(%{"notify" => "ops"})
      #=> %{to: ["ops"], on: [:parked, :failed]}
  """
  @spec route(map()) :: route() | nil
  def route(%{"notify" => %{"to" => to} = notify}),
    do: %{to: List.wrap(to), on: Enum.map(Map.get(notify, "on", ~w(parked failed)), &kind/1)}

  def route(%{"notify" => to}) when is_binary(to) or is_list(to),
    do: %{to: List.wrap(to), on: [:parked, :failed]}

  def route(_definition), do: nil

  defp kind("parked"), do: :parked
  defp kind("failed"), do: :failed
  defp kind("finished"), do: :finished

  @doc "Returns `:ok` if every place `definition` routes to exists and accepts the agent `id`."
  @spec check(Wardrik.t(), String.t(), map()) :: :ok | {:error, Error.t()}
  def check(wardrik, id, definition) do
    case route(definition) do
      nil -> :ok
      %{to: to} -> Enum.find_value(to, :ok, &refused(wardrik, id, &1))
    end
  end

  defp refused(wardrik, id, name) do
    case place(wardrik, name) do
      {:room, _channel, _room} ->
        nil

      {:target, _module, opts} ->
        if tells?(opts, id),
          do: nil,
          else: invalid("The notify target #{name} doesn't tell #{Orgs.org(id)}'s agents.")

      :error ->
        invalid("There's no notify target #{name} here, nor a channel that posts in it.")
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}

  @doc """
  Sends `notice` to `name`, a target or a channel's room.

  Returns `{:skip, why}` if there's nowhere to send it. Skips aren't retried.
  """
  @spec deliver(Wardrik.t(), String.t(), Notice.t()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def deliver(wardrik, name, notice) do
    case place(wardrik, name) do
      {:room, channel, room} ->
        Wardrik.Notify.Room.deliver(notice, wardrik: wardrik.name, channel: channel, room: room)

      {:target, module, opts} ->
        if tells?(opts, notice.agent),
          do:
            module.deliver(
              notice,
              [wardrik: wardrik.name, target: name] ++
                Wardrik.Sealed.resolved(wardrik, "the target #{name}", opts)
            ),
          else: {:skip, "which doesn't tell #{Orgs.org(notice.agent)}'s agents"}

      :error ->
        {:skip, "which isn't a target or a channel's room here"}
    end
  end

  defp place(wardrik, name) do
    with :error <- Map.fetch(wardrik.notify.targets, name),
         [channel, room] <- String.split(name, ":", parts: 2),
         true <- Map.has_key?(wardrik.channels, channel) and room != "" do
      {:room, channel, room}
    else
      {:ok, {module, opts}} -> {:target, module, opts}
      _neither -> :error
    end
  end

  defp tells?(opts, id) do
    case Keyword.get(opts, :orgs, :all) do
      :all -> true
      orgs -> Orgs.org(id) in orgs
    end
  end
end
