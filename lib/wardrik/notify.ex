defmodule Wardrik.Notify do
  @schema NimbleOptions.new!(
            targets: [
              type:
                {:list, {:tuple, [{:or, [:atom, :string]}, {:tuple, [:atom, :keyword_list]}]}},
              default: [],
              doc: """
              The deployment's targets by name, as `{module, opts}`, each checked against its
              module's `c:schema/0` as Wardrik starts. A target's `:orgs` limits it to those
              orgs' agents. Routing another org's agent to it is refused.
              """
            ],
            retries: [
              type: :keyword_list,
              default: [attempts: 3, max_wait: 10_000],
              doc: """
              How failed deliveries are retried. See `WardrikCore.Retry`. After that, the notice
              is logged and dropped.
              """
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: """
              Merged into the `Req` request of each webhook an org or person adds. Those never
              follow a redirect.
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

  ## Targets by owner

  An org or person adds webhooks with `notify_targets.add`, and their agents route to them by
  name. A name resolves along `Wardrik.Owners.chain/1`, nearest first: a person's own, their
  org's, the deployment's, then the targets in `:notify`.

      Wardrik.run(scope, "notify_targets.add", %{
        "owner" => "acme",
        "name" => "ops",
        "url" => "https://hooks.acme.example/wardrik",
        "secret" => %{"name" => "OPS_HOOK_SECRET"}
      })

  Now `notify: "ops"` posts acme's agents' notices there, in place of the deployment's `ops`.
  The secret is read from acme's vault as each notice is sent. The URL must pass Wardrik's
  `:egress` as it's added and as each notice is sent.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Delivery

  One process in the cluster follows every agent's log. Each notice is sent at least once: after
  a restart it picks up where it left off. Tell repeats apart by agent, kind and `at`.
  """

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Notice
  alias Wardrik.Notify.Room
  alias Wardrik.Notify.Webhook
  alias Wardrik.Orgs
  alias Wardrik.Owners

  @passed [wardrik: [type: :atom], target: [type: :string], orgs: [type: {:list, :string}]]

  @typedoc "Where an agent's notices go (`:to`), and which kinds are sent (`:on`)."
  @type route() :: %{to: [String.t()], on: [Notice.kind()]}

  @typedoc """
  A target agents route to: who holds it, whether it's from `:notify` or added since, and the
  module and options that send to it.
  """
  @type target() :: %{
          owner: Owners.t(),
          name: String.t(),
          source: :config | :runtime,
          module: module(),
          opts: keyword()
        }

  @doc """
  Sends `notice`. Returns `{:skip, why}` if it shouldn't be sent, or `{:error, reason}` to retry.

  `opts` are the target's own, plus `:wardrik`, the instance, and `:target`, the target's name.
  """
  @callback deliver(Notice.t(), opts :: keyword()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc """
  Returns the options a target takes, as a `NimbleOptions` schema.

  Wardrik checks each target's options against it as it starts, so `deliver/2` gets them checked,
  with their defaults. It needn't name `:wardrik`, `:target` or `:orgs`. Where an option takes a
  secret, allow `{:secret, name}`: `deliver/2` gets the deployment's secret of that name.
  """
  @callback schema() :: keyword()

  @optional_callbacks schema: 0

  @doc """
  Returns the `:notify` option's targets by name, each with its options checked, and its retries.

  Raises `ArgumentError`, naming the target, if a target's options don't fit its `c:schema/0`.
  """
  @spec settings(keyword() | nil) :: %{
          targets: %{String.t() => {module(), keyword()}},
          retries: keyword(),
          req_options: keyword()
        }
  def settings(nil), do: settings([])

  def settings(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %{
      targets: Map.new(opts[:targets], &checked/1),
      retries: opts[:retries],
      req_options: opts[:req_options]
    }
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
  Returns the targets `owner`'s agents route to, nearest first along `Wardrik.Owners.chain/1`:
  each owner's own, then the deployment's from `:notify` that tell `owner`'s org. The nearest of a
  name wins.
  """
  @spec targets(Wardrik.t(), Owners.t()) :: [target()]
  def targets(wardrik, owner) do
    {:ok, %{org: org}} = Owners.parse(owner)

    owner
    |> Owners.chain()
    |> Enum.flat_map(&added(wardrik, &1))
    |> Kernel.++(for target <- configured(wardrik), tells?(target.opts, org), do: target)
    |> Enum.uniq_by(& &1.name)
  end

  @doc "Returns the key `owner`'s target `name` is kept at, in Wardrik's own store."
  @spec key(Owners.t(), String.t()) :: String.t()
  def key(owner, name), do: prefix(owner) <> name

  defp added(wardrik, owner) do
    store = store(wardrik)
    prefix = prefix(owner)

    for key <- WardrikStore.keys(store, prefix),
        opts when is_list(opts) <- [WardrikStore.get(store, key)] do
      name = String.replace_prefix(key, prefix, "")
      %{owner: owner, name: name, source: :runtime, module: Webhook, opts: opts}
    end
  end

  defp configured(wardrik) do
    for {name, {module, opts}} <- wardrik.notify.targets do
      %{owner: "deployment", name: name, source: :config, module: module, opts: opts}
    end
  end

  defp prefix(owner), do: "notify_targets/" <> URI.encode_www_form(owner) <> "/"

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")

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
    case place(wardrik, id, name) do
      :untold ->
        invalid("The notify target #{name} doesn't tell #{Orgs.org(id)}'s agents.")

      :error ->
        invalid("There's no notify target #{name} here, nor a channel that posts in it.")

      _place ->
        nil
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}

  @doc """
  Sends `notice` to `name`: the nearest target of that name along the agent's owner's chain, or a
  channel's room.

  Returns `{:skip, why}` if there's nowhere to send it. Skips aren't retried.
  """
  @spec deliver(Wardrik.t(), String.t(), Notice.t()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def deliver(wardrik, name, notice) do
    case place(wardrik, notice.agent, name) do
      {:room, channel, room} ->
        Room.deliver(notice, wardrik: wardrik.name, channel: channel, room: room, approvers: [])

      {:target, %{source: :config, module: module, opts: opts}} ->
        module.deliver(
          notice,
          [wardrik: wardrik.name, target: name] ++
            Wardrik.Sealed.resolved(wardrik, "the target #{name}", opts)
        )

      {:target, %{source: :runtime} = target} ->
        posted(wardrik, target, notice)

      :untold ->
        {:skip, "which doesn't tell #{Orgs.org(notice.agent)}'s agents"}

      :error ->
        {:skip, "which isn't a target or a channel's room here"}
    end
  end

  # A webhook an org or person added: its URL is checked again, since where it resolves can
  # change, and its secret is read from its owner's vault.
  defp posted(wardrik, %{owner: owner, name: name, opts: opts}, notice) do
    with :ok <- reachable(wardrik, opts[:url]),
         {:ok, secret} <- signing(wardrik, owner, opts[:secret]) do
      Webhook.deliver(notice,
        wardrik: wardrik.name,
        target: name,
        url: opts[:url],
        secret: secret,
        req_options: Keyword.merge(wardrik.notify.req_options, redirect: false)
      )
    end
  end

  defp reachable(wardrik, url) do
    case wardrik.egress.(url) do
      :ok -> :ok
      {:error, why} -> {:skip, "but it can't be reached: #{why}"}
    end
  end

  defp signing(_wardrik, _owner, nil), do: {:ok, nil}

  defp signing(wardrik, owner, {:secret, name}) do
    case Wardrik.Sealed.fetch(wardrik, owner, name) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> {:skip, "but #{owner} holds no secret #{name} to sign it with"}
    end
  end

  defp place(wardrik, id, name) do
    {:ok, %AgentID{owner: owner}} = AgentID.parse(id)

    case Enum.find(targets(wardrik, owner), &(&1.name == name)) do
      nil -> elsewhere(wardrik, name)
      target -> {:target, target}
    end
  end

  # A target in `:notify` that isn't among the agent's targets tells other orgs alone.
  defp elsewhere(wardrik, name) do
    with :error <- Map.fetch(wardrik.notify.targets, name),
         [channel, room] <- String.split(name, ":", parts: 2),
         true <- Map.has_key?(wardrik.channels, channel) and room != "" do
      {:room, channel, room}
    else
      {:ok, _target} -> :untold
      _neither -> :error
    end
  end

  defp tells?(_opts, nil), do: true

  defp tells?(opts, org) do
    case Keyword.get(opts, :orgs, :all) do
      :all -> true
      orgs -> org in orgs
    end
  end
end
