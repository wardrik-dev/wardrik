defmodule Wardrik.Notify do
  @schema NimbleOptions.new!(
            targets: [
              type:
                {:list, {:tuple, [{:or, [:atom, :string]}, {:tuple, [:atom, :keyword_list]}]}},
              default: [],
              doc: """
              The deployment's targets by name, as `{module, opts}`, each checked against its
              module's `c:schema/0` as Wardrik starts.
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
          audit:
            {Wardrik.Notify.Webhook,
             url: "https://hooks.example.com/wardrik", secret: {:secret, "HOOK_SECRET"}},
          ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops"}
        ]
      ]

  An agent's definition routes its notices with `notify`:

      # A target
      notify: "ops"

      # A room in one of Wardrik's channels, in the workspace the agent's resolver gives
      notify: "slack:#updates"

      # Several
      notify: ["ops", "slack:#updates"]

      # Which kinds of `Wardrik.Notice` to send. `["parked", "failed"]` unless set.
      notify: %{to: ["ops"], on: ["finished"]}

  Conversations aren't routed anywhere.

  ## Targets your app gives

  A target in `:notify` reaches every agent its resolver gives it to. Your app can also give an
  agent a target of its own, as `{module, opts}`, such as a webhook one of your customers added:

      %Wardrik.Resolved{
        notify: %{
          "ops" => "ops",
          "alerts" => {Wardrik.Notify.Webhook, url: customer.webhook_url, secret: customer.secret}
        }
      }

  Its options are checked against its module's `c:schema/0` as the agent is resolved. A
  `{:secret, name}` in them isn't read: give the secret itself. See `Wardrik.Resolver`.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Delivery

  One process in the cluster follows every agent's log. Each notice is sent at least once: after
  a restart it picks up where it left off. Tell repeats apart by agent, kind and `at`.
  """

  alias Wardrik.Error
  alias Wardrik.Notice
  alias Wardrik.Notify.Room

  @passed [wardrik: [type: :atom], target: [type: :string]]

  @typedoc "Where an agent's notices go (`:to`), and which kinds are sent (`:on`)."
  @type route() :: %{to: [String.t()], on: [Notice.kind()]}

  @doc """
  Sends `notice`. Returns `{:skip, why}` if it shouldn't be sent, or `{:error, reason}` to retry.

  `opts` are the target's own, plus `:wardrik`, the instance, and `:target`, the target's name.
  """
  @callback deliver(Notice.t(), opts :: keyword()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc """
  Returns the options a target takes, as a `NimbleOptions` schema.

  Wardrik checks each target's options against it as it starts, so `deliver/2` gets them checked,
  with their defaults. It needn't name `:wardrik` or `:target`. Where an option takes a secret,
  allow `{:secret, name}`: a target in `:notify` gets the deployment's secret of that name.
  """
  @callback schema() :: keyword()

  @optional_callbacks schema: 0

  @doc """
  Returns the `:notify` option's targets by name, each with its options checked, and its retries.

  Raises `ArgumentError`, naming the target, if a target's options don't fit its `c:schema/0`.
  """
  @spec settings(keyword() | nil) :: %{
          targets: %{String.t() => {module(), keyword()}},
          retries: keyword()
        }
  def settings(nil), do: settings([])

  def settings(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %{targets: Map.new(opts[:targets], &checked/1), retries: opts[:retries]}
  end

  defp checked({name, {module, opts}}) do
    name = to_string(name)
    {name, {module, checked(name, module, opts)}}
  end

  defp checked(name, module, opts) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :schema, 0),
         {:error, error} <- NimbleOptions.validate(opts, module.schema() ++ @passed) do
      raise ArgumentError,
            "The notify target #{name}'s options are invalid: #{Exception.message(error)}"
    else
      {:ok, opts} -> opts
      false -> opts
    end
  end

  @doc """
  Checks a target your app gives as `{module, opts}` against its module's `c:schema/0`. Returns
  it with its options' defaults, or why it doesn't fit.
  """
  @spec given(term()) :: {:ok, {module(), keyword()}} | {:error, String.t()}
  def given({module, opts}) when is_atom(module) and is_list(opts) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :deliver, 2),
         :ok <- unsealed(opts),
         {:ok, opts} <- options(module, opts) do
      {:ok, {module, opts}}
    else
      false -> {:error, "#{inspect(module)} isn't a notify target"}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, why} -> {:error, why}
    end
  end

  def given(other), do: {:error, "#{inspect(other)} isn't a target's name or {module, opts}"}

  defp unsealed(opts) do
    case Enum.find(opts, &match?({_key, {:secret, _name}}, &1)) do
      nil -> :ok
      {key, _secret} -> {:error, "its #{key} names a secret, which isn't read: give the secret"}
    end
  end

  defp options(module, opts) do
    if function_exported?(module, :schema, 0),
      do: NimbleOptions.validate(opts, module.schema()),
      else: {:ok, opts}
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

  @doc """
  Returns `:ok` if every place `definition` routes to is in `notify`, the targets the agent was
  resolved with, or is a channel's room.
  """
  @spec check(Wardrik.t(), Wardrik.Resolved.notify(), map()) :: :ok | {:error, Error.t()}
  def check(wardrik, notify, definition) do
    case route(definition) do
      nil -> :ok
      %{to: to} -> Enum.find_value(to, :ok, &refused(wardrik, notify, &1))
    end
  end

  defp refused(wardrik, notify, name) do
    case place(wardrik, notify, name) do
      :error ->
        {:error,
         Error.new(
           :invalid_request,
           "There's no notify target #{name} here, nor a channel that posts in it."
         )}

      _place ->
        nil
    end
  end

  @doc """
  Sends `notice` to `name`: the target the agent was resolved with by that name, or a channel's
  room. See `Wardrik.Resolver`.

  Returns `{:skip, why}` if there's nowhere to send it. Skips aren't retried.
  """
  @spec deliver(Wardrik.t(), String.t(), Notice.t()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def deliver(wardrik, name, notice) do
    with {:ok, resolved} <- Wardrik.Resolver.defined(wardrik, notice.agent) do
      sent(wardrik, place(wardrik, resolved.notify, name), notice)
    end
  end

  defp sent(wardrik, {:room, channel, room}, notice),
    do: Room.deliver(notice, wardrik: wardrik.name, channel: channel, room: room)

  defp sent(wardrik, {:configured, name, {module, opts}}, notice),
    do:
      module.deliver(
        notice,
        [wardrik: wardrik.name, target: name] ++
          Wardrik.Sealed.resolved(wardrik, "the target #{name}", opts)
      )

  # Your app's own target holds its secrets itself: the deployment's aren't read for it.
  defp sent(wardrik, {:given, name, {module, opts}}, notice),
    do: module.deliver(notice, [wardrik: wardrik.name, target: name] ++ opts)

  defp sent(_wardrik, :error, _notice),
    do: {:skip, "which isn't a target or a channel's room here"}

  defp place(wardrik, notify, name) do
    case Map.fetch(notify, name) do
      {:ok, {_module, _opts} = target} -> {:given, name, target}
      {:ok, key} -> configured(wardrik, key, name)
      :error -> room(wardrik, name)
    end
  end

  defp configured(wardrik, key, name) do
    case Map.fetch(wardrik.notify.targets, key) do
      {:ok, target} -> {:configured, key, target}
      :error -> room(wardrik, name)
    end
  end

  defp room(wardrik, name) do
    with [channel, room] <- String.split(name, ":", parts: 2),
         true <- Map.has_key?(wardrik.channels, channel) and room != "" do
      {:room, channel, room}
    else
      _neither -> :error
    end
  end
end
