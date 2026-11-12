defmodule Wardrik.Notify do
  @schema NimbleOptions.new!(
            targets: [
              type:
                {:list, {:tuple, [{:or, [:atom, :string]}, {:tuple, [:atom, :keyword_list]}]}},
              default: [],
              doc: "Targets by name, as `{module, opts}`."
            ],
            retries: [
              type: :keyword_list,
              default: [attempts: 3, max_wait: 10_000],
              doc: "How failed deliveries retry. See `WardrikCore.Retry`."
            ]
          )

  @moduledoc """
  Tells people when an agent parks, fails or finishes while nobody watches.

      # Wardrik's options
      notify: [
        targets: [
          audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: {:secret, "HOOK_SECRET"}},
          ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops"}
        ]
      ]

  A definition routes its notices with `notify`:

      notify: "ops"
      notify: "slack:#updates"
      notify: ["ops", "slack:#updates"]
      notify: %{to: ["ops"], on: ["finished"]}

    * `on` defaults to `["parked", "failed"]`.
    * An agent reaches only the targets `Wardrik.Resolved`'s `:notify` gives it.
    * Your resolver can also give a target of its own, as `{module, opts}`, with secrets as values.
    * The node an agent runs on tells of it, retrying as `:retries` says. A notice whose node stops
      first is lost; `interrupts.list` still shows what waits. Tell repeats apart by agent, kind
      and `at`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Wardrik.Error
  alias Wardrik.Notice
  alias Wardrik.Notify.Room

  @passed [wardrik: [type: :atom], target: [type: :string]]

  @typedoc "Where an agent's notices go (`:to`), and which kinds are sent (`:on`)."
  @type route() :: %{to: [String.t()], on: [Notice.kind()]}

  @doc """
  Sends `notice`. Returns `{:skip, why}` not to send it, or `{:error, reason}` to retry.

  `opts` are the target's own, plus `:wardrik` and `:target`.
  """
  @callback deliver(Notice.t(), opts :: keyword()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc """
  Returns the target's options as a `NimbleOptions` schema. Wardrik checks them as it starts.

  Allow `{:secret, name}` where an option takes a secret.
  """
  @callback schema() :: keyword()

  @optional_callbacks schema: 0

  @doc """
  Returns the `:notify` option's checked targets and retries. Raises `ArgumentError` on a bad target.
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
  Checks a `{module, opts}` target against its `c:schema/0`. Returns it with defaults, or why not.
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
  Returns `:ok` if every place `definition` routes to is in `notify` or is a channel's room.
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
  Sends `notice` to the resolved target or channel room `name`. `{:skip, why}` if there's none.
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
          Wardrik.Vault.Lookup.resolved(wardrik, "the target #{name}", opts)
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
