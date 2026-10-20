defmodule WardrikNotify do
  @moduledoc """
  Tells people what agents are doing when nobody is watching: a turn that
  parked on a question, one that failed, and, when asked for, what a turn
  answered.

  `config.yaml` names targets, and an agent's definition routes it to them,
  or to a room of one of `config.yaml`'s `channels`, as `<channel>:<room>`.
  A target in a chat medium is a room of a channel too, and names whom it
  asks:

      notify:
        ops:
          channel: slack
          room: "#ops"
          approvers: ["@maria"]
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
            secret: ${WARDRIK_WEBHOOK_SECRET}

      # agents/triage.md
      notify: {to: [ops, "slack:#updates"], on: [parked, failed, finished]}

  A target is a module implementing this behaviour and its options.
  `WardrikNotify.Webhook` ships with the package, `WardrikChannel.Notices`
  with `wardrik_channel`, and a host names its own beside them, as it
  attaches the package to its `Wardrik.Host` (see `attach/2`):

      host =
        WardrikNotify.attach(host,
          targets: [
            ops:
              {WardrikChannel.Notices,
               channel: {WardrikSlack, []}, installation: installation, room: "#ops"},
            pager: {MyApp.Pager, opts}
          ]
        )

  A target's `:orgs` is the orgs whose agents it tells, every org's unless it
  says. `config/1` reads `config.yaml`'s `notify` into the targets.

  A room a route names, `slack:#updates`, is posted in through the
  `WardrikNotify.Rooms` the host holds as this module's `:rooms` setting,
  which `wardrik_channel` registers as it attaches: where the channel
  offers the agent's org, in a workspace the channel is installed in for
  the agent's own owner, so each org's agents post in their own, and one
  whose owner has none posts nothing, with a warning. It asks nobody: who may answer is what the token the host's
  `Wardrik.Issuer` issues them allows.

  `WardrikNotify.Keeper`, one in the cluster, follows every agent's log
  as the deployment, `Wardrik.Principal.deployment/0`, so the host's
  `Wardrik.Issuer` allows `deployment` `agent.events` on `*/agent/*`. For
  each event it reads the agent's route from its definition, sends each
  `WardrikNotify.Notice` the route asks for (see `WardrikNotify.Listener`),
  and writes down its place: after a restart it carries on from there, so
  each notice is sent at least once, and a receiver tells a repeat by its
  agent, its `event` and its `at`. A notice that cannot be delivered is
  logged; nothing retries it past the listener's own attempts.
  """

  alias WardrikNotify.Notice

  @typedoc "Targets by name: the module that delivers to each, and its options."
  @type targets() :: [{atom(), {module(), keyword()}}]

  @target "is a webhook, or a channel and a room in it"

  @doc """
  `host` with `WardrikNotify.Supervisor` among its children, delivering to
  `:targets` and the rooms of the host's channels, as the agents'
  definitions on the host route them. `:req_options`, `:backoff` and
  `:name` are the supervisor's.
  """
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    opts = Keyword.validate!(opts, [:req_options, :backoff, :name, targets: []])
    Wardrik.Host.child(host, {WardrikNotify.Supervisor, opts})
  end

  @doc """
  Reads `config.yaml`'s `notify`, each target by its name, into the
  options `attach/2` takes, or the key that does not read, as a path within
  the section, and why. A target is a webhook, its `url` and `secret`, or a
  room of a channel, which posts through `WardrikChannel.Notices` once the
  host finds the channel `channel` names.

      WardrikNotify.config(%{"ops" => %{"channel" => "slack", "room" => "#ops"}})
      #=> {:ok, targets: [ops: {WardrikChannel.Notices, channel: "slack", room: "#ops", approvers: []}]}
  """
  @spec config(map() | nil) :: {:ok, keyword()} | {:error, [String.t()], String.t()}
  def config(nil), do: {:ok, targets: []}

  def config(%{} = section) do
    {:ok, targets: for({name, target} <- section, do: {named(name), target!(name, target)})}
  catch
    {:invalid, path, message} -> {:error, path, message}
  end

  def config(_section), do: {:error, [], "is a set of keys"}

  defp target!(name, %{"channel" => _} = target) do
    known!(target, ~w(channel room approvers), [name])

    for key <- ~w(channel room),
        not (is_binary(target[key]) and target[key] != ""),
        do: invalid!([name, key], "is required")

    approvers = Map.get(target, "approvers", [])

    unless is_list(approvers) and Enum.all?(approvers, &is_binary/1),
      do: invalid!([name, "approvers"], "is a list of who may answer, as the channel names them")

    {WardrikChannel.Notices,
     channel: target["channel"], room: target["room"], approvers: approvers}
  end

  defp target!(name, %{"webhook" => %{} = webhook} = target) when map_size(target) == 1 do
    known!(webhook, ~w(url secret), [name, "webhook"])
    unless Map.has_key?(webhook, "url"), do: invalid!([name, "webhook", "url"], "is required")

    {WardrikNotify.Webhook,
     for(
       {key, value} <- [url: webhook["url"], secret: webhook["secret"]],
       value != nil,
       do: {key, value}
     )}
  end

  defp target!(name, %{"webhook" => _webhook} = target) when map_size(target) == 1,
    do: invalid!([name, "webhook"], "is a set of keys")

  defp target!(name, _target), do: invalid!([name], @target)

  defp named(name) do
    if String.contains?(name, ":"),
      do: invalid!([name], "is not a target's name: one holds no :, which writes a room")

    # reach:disable-next-line unsafe_atom_creation -- config.yaml's own target names
    String.to_atom(name)
  end

  defp known!(table, keys, path) do
    case Map.keys(table) -- keys do
      [] ->
        :ok

      [key | _] ->
        invalid!(path ++ [key], "is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  defp invalid!(path, message), do: throw({:invalid, path, message})

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
end
