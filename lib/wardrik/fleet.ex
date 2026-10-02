defmodule Wardrik.Fleet do
  @moduledoc """
  Every agent in the cluster: what is running, what it is doing, and how to
  stop it.

  | Function | Answers |
  | --- | --- |
  | `put/1` | start an agent from its `Wardrik.Agent.Spec`, or bring a running one to it |
  | `list/1` | which agents are running, and what each is doing |
  | `watch/1` | the same, as messages, whenever it changes |
  | `kill/1` | interrupt everything under a prefix |
  | `forget/1`, `forget_under/1` | remove an agent, or every agent under a prefix, and its store |
  | `move/2` | restart an agent on another node, as it was |
  | `whereis/1` | the pid behind a key, on whatever node holds it |
  | `stored?/1` | whether the store holds an agent, running or stopped |

  ## Keys

  An agent's key is its address across the cluster and its topic on the event
  bus. Every agent belongs to an org, and may work for one of its users:

  | Key | The agent |
  | --- | --- |
  | `acme/triage` | acme's own `triage` |
  | `acme/@jon/triage` | jon's `triage`, in acme |

  So the ways a fleet is sliced are prefixes of one string:

      Wardrik.Fleet.list()              # everything
      Wardrik.Fleet.list("acme/")       # one tenant
      Wardrik.Fleet.list("acme/@jon/")  # one person's agents

  `key/2` builds one from a name and the host's own org and user values,
  written down through `Wardrik.Fleet.Segment`. The agent's scope reads `:org`
  and `:user` back out of the key, so identity is given once:

      key = Wardrik.Fleet.key("researcher", org: current_org, user: current_user)
      Wardrik.Fleet.spawn(key, config: config)

  A key without an `:org` is in the deployment's org, where one is configured,
  and refused where none is:

      config :wardrik, Wardrik.Fleet, org: "app"

      Wardrik.Fleet.key("researcher", user: "42")  #=> "app/@42/researcher"

  A segment is the org, the user or the name. It holds no `/` or whitespace,
  and does not begin with `@`, which marks the user, or `_`, which is kept
  for the fleet's own records. A segment is in every event's `source`, every
  store key and every log line naming the agent, so a user's should be an
  opaque id rather than an email address.

  ## Listing

  Agents publish what they are doing as registry metadata when it changes, and
  the registry replicates between nodes, so `list/1` is a table read that sends
  no messages and `watch/1` needs no polling.

  ## Durability

  Agents are `DurableServer` processes: one per key across the cluster under a
  lock, state written to the store on every change that matters, and restarted
  on another node when theirs is lost. See `Wardrik.Agent.State` for what survives
  a restart and what does not.
  """

  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Fleet.Member
  alias Wardrik.Fleet.Segment
  alias Wardrik.Schedule

  @name __MODULE__
  @prefix "agents/"
  @segment ~r/\A[^\/@_\s][^\/\s]*\z/u

  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # -- keys ------------------------------------------------------------------

  @doc """
  The key an agent is addressed by, from its name, the `:org` it belongs to
  and the `:user` it works for, if it works for one. Each is written down
  through `Wardrik.Fleet.Segment`. Without an `:org` the key is in `org/0`,
  and raises where there is none.
  """
  @spec key(String.t(), keyword()) :: String.t()
  def key(name, opts \\ []) when is_binary(name) do
    org = segment!(opts[:org] || org() || raise(ArgumentError, no_org()), "org")
    name = segment!(name, "name")

    case opts[:user] do
      nil -> org <> "/" <> name
      user -> org <> "/@" <> segment!(user, "user") <> "/" <> name
    end
  end

  @doc "The deployment's org, which a key without one is in, or `nil` where none is configured."
  @spec org() :: String.t() | nil
  def org, do: :wardrik |> Application.get_env(__MODULE__, []) |> Keyword.get(:org)

  defp no_org,
    do:
      "an agent key needs an org: pass :org, or set one for the deployment with " <>
        "config :wardrik, Wardrik.Fleet, org: \"...\""

  defp segment!(value, what) do
    segment = Segment.to_segment(value)

    if segment?(segment),
      do: segment,
      else:
        raise(
          ArgumentError,
          "an agent's #{what} is #{inspect(segment)} from #{inspect(value)}, which is not a " <>
            "segment; a segment holds no / or whitespace and does not begin with @ or _"
        )
  end

  @doc "Whether `text` can be one segment of a key: an org, a user or a name."
  @spec segment?(term()) :: boolean()
  def segment?(text) when is_binary(text),
    do: text not in [".", ".."] and Regex.match?(@segment, text)

  def segment?(_text), do: false

  @doc """
  The org, user and name a key is made of, with `nil` for the user of an
  org's own agent. Raises on anything `key/2` would not have built.
  """
  @spec parse(String.t()) :: {String.t(), String.t() | nil, String.t()}
  def parse(key) when is_binary(key) do
    case cast(key) do
      {:ok, parts} ->
        parts

      :error ->
        raise ArgumentError, "an agent key is org/name or org/@user/name, got #{inspect(key)}"
    end
  end

  @doc "`parse/1`, answering `:error` rather than raising."
  @spec cast(String.t()) :: {:ok, {String.t(), String.t() | nil, String.t()}} | :error
  def cast(key) when is_binary(key) do
    case String.split(key, "/") do
      [org, "@" <> user, name] -> segments({org, user, name}, [org, user, name])
      [org, name] -> segments({org, nil, name}, [org, name])
      _other -> :error
    end
  end

  defp segments(parts, segments),
    do: if(Enum.all?(segments, &segment?/1), do: {:ok, parts}, else: :error)

  @doc """
  The key `text` names, where an agent in `org/0` may be named without it: an
  org's own agent by its name, and a user's as `@user/name`.

      Wardrik.Fleet.expand("triage")            #=> {:ok, "app/triage"}
      Wardrik.Fleet.expand("@jon/triage")       #=> {:ok, "app/@jon/triage"}
      Wardrik.Fleet.expand("acme/@jon/triage")  #=> {:ok, "acme/@jon/triage"}
  """
  @spec expand(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def expand(text) when is_binary(text) do
    case String.split(text, "/") do
      [_name] -> in_org(text, &key_of/2)
      ["@" <> _user, _name] -> in_org(text, &key_of/2)
      _whole -> key_of(text, text)
    end
  end

  defp key_of(key, text),
    do: if(cast(key) == :error, do: {:error, not_a_key(text)}, else: {:ok, key})

  @doc """
  The prefix `text` names, as `expand/1` reads a key: `""` for every agent, an
  org as `acme/`, a user as `acme/@jon/`, or `@jon/` for one in `org/0`. Text
  that does not end in `/` is a key, and names that agent alone.
  """
  @spec expand_prefix(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def expand_prefix(""), do: {:ok, ""}

  def expand_prefix(text) when is_binary(text) do
    case String.split(text, "/") do
      ["@" <> _user, ""] -> in_org(text, &scope_of/2)
      [_org, ""] -> scope_of(text, text)
      [_org, "@" <> _user, ""] -> scope_of(text, text)
      _key -> expand(text)
    end
  end

  defp scope_of(prefix, text) do
    case scope(prefix) do
      {:ok, _prefix} = ok -> ok
      {:error, _message} -> {:error, not_a_scope(text)}
    end
  end

  # `text` in the deployment's org, as `check` reads it.
  defp in_org(text, check) do
    case org() do
      nil -> {:error, "#{text} names no org, and the deployment has none; name it as org/#{text}"}
      org -> check.(org <> "/" <> text, text)
    end
  end

  @doc """
  The prefix of keys `text` reaches: `""` for every agent, `acme` or `acme/`
  for an org's, `acme/@jon` or `acme/@jon/` for one user's, or a key for one
  agent alone. A `Wardrik.Grant`'s scope, and a shared tree's, are read this
  way.
  """
  @spec scope(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def scope(""), do: {:ok, ""}

  def scope(text) when is_binary(text) do
    trimmed = String.trim_trailing(text, "/")

    case String.split(trimmed, "/") do
      [org] -> scoped(trimmed <> "/", [org], text)
      [org, "@" <> user] -> scoped(trimmed <> "/", [org, user], text)
      _key -> if cast(trimmed) == :error, do: {:error, not_a_scope(text)}, else: {:ok, trimmed}
    end
  end

  defp scoped(prefix, segments, text),
    do:
      if(Enum.all?(segments, &segment?/1),
        do: {:ok, prefix},
        else: {:error, not_a_scope(text)}
      )

  defp not_a_key(text),
    do: "#{text} is not an agent key; a key is name, @user/name, org/name or org/@user/name"

  defp not_a_scope(text),
    do: "#{inspect(text)} is not a scope; a scope is org/, org/@user/ or a key"

  # -- lifecycle -------------------------------------------------------------

  @doc """
  Starts an agent in the fleet, or returns the one already running under its key.

  Options are everything `Wardrik.Agent.initial_state/2` takes, and `:node`, the
  node to start it on. Without one the agent is placed on whichever node has
  capacity, so the pid may be remote either way.

      {:ok, pid} = Wardrik.Fleet.spawn(Wardrik.Fleet.key("researcher", org: "acme"), config: config)
      {:ok, pid} = Wardrik.Fleet.spawn(key, config: config, node: :"wardrik_b@host")
  """
  @spec spawn(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(key, opts \\ []) when is_binary(key) do
    {node, opts} = Keyword.pop(opts, :node)

    child(key, opts) |> start(node) |> started()
  end

  @doc """
  Makes the fleet match `spec`: starts the agent it describes where none runs
  under its key, gives the one that does the spec's config and seams with
  `Wardrik.Agent.configure/2`, and brings its schedules to the spec's, unless the
  spec's `schedules` is `nil`. The agent keeps its conversation either way.

      {:ok, pid} = Wardrik.Fleet.put(Wardrik.Agent.Spec.new(name: "triage", org: "acme"))
  """
  @spec put(Spec.t()) :: {:ok, pid()} | {:error, term()}
  def put(%Spec{} = spec) do
    options = Spec.options(spec)

    with {:ok, pid} <- spawn(Spec.key(spec), options),
         :ok <- Agent.configure(pid, options),
         :ok <- sync(Spec.key(spec), spec.schedules) do
      {:ok, pid}
    end
  end

  defp sync(_key, nil), do: :ok
  defp sync(key, schedules), do: Schedule.sync(key, schedules)

  @doc """
  Stops an agent and starts it again on `node`, with the state it had.

      {:ok, pid} = Wardrik.Fleet.move("acme/@jon/researcher", :"wardrik_b@host")
  """
  @spec move(String.t(), node()) :: {:ok, pid()} | {:error, term()}
  def move(key, node) when is_binary(key) and is_atom(node) do
    @name
    |> DurableServer.Supervisor.rehome_child(child(key, []), target_node: node)
    |> started()
  end

  defp child(key, opts), do: {Agent, key: key, initial_state: Agent.initial_state(opts, key)}

  defp start(child, nil), do: DurableServer.Supervisor.ensure_started_child(@name, child)

  defp start(child, node) do
    args = [@name, child, [local_only: true]]
    :erpc.call(node, DurableServer.Supervisor, :ensure_started_child, args)
  catch
    :error, {:erpc, reason} -> {:error, {:erpc, reason}}
  end

  defp started({:ok, {pid, _meta}}), do: {:ok, pid}
  defp started({:error, reason}), do: {:error, reason}

  @doc """
  Stops an agent, syncing its state first so `spawn/2` brings it back as it was.

  The agent stays stopped until something spawns it again: a graceful stop
  would leave a permanent agent eligible for the supervisor's own restart.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(key) when is_binary(key) do
    DurableServer.Supervisor.terminate_child_permanent(@name, key)
  end

  @doc "Whether an agent is kept under `key`, running or stopped."
  @spec stored?(String.t()) :: boolean()
  def stored?(key) when is_binary(key),
    do: match?({:ok, _info}, DurableServer.Supervisor.get_server_info(@name, key))

  @doc "Stops an agent and deletes everything it had, its schedules included, permanently."
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(key) when is_binary(key) do
    with :ok <- Schedule.sync(key, []) do
      DurableServer.Supervisor.terminate_and_delete_child(@name, key)
    end
  end

  @doc """
  Forgets every running agent under `prefix`, and returns how many.

  Agents that are stored but not running are left where they are.
  """
  @spec forget_under(String.t()) :: non_neg_integer()
  def forget_under(prefix) when is_binary(prefix) do
    members = list(prefix)
    Enum.each(members, &forget(&1.key))
    length(members)
  end

  @doc "The pid behind a key, wherever in the cluster it is, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(key) when is_binary(key) do
    case DurableServer.Supervisor.lookup(@name, key) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc "One agent as the fleet sees it, or `nil` when nothing holds that key."
  @spec lookup(String.t()) :: Member.t() | nil
  def lookup(key) when is_binary(key) do
    case DurableServer.Supervisor.lookup(@name, key) do
      {pid, meta} -> Member.new(key, pid, meta)
      nil -> nil
    end
  end

  # -- the fleet -------------------------------------------------------------

  @doc """
  Every agent whose key starts with `prefix`, across the cluster, sorted by key.

  Reads each node's registry, so this is one call per node in the cluster.
  `watch/1` is the cheaper way to keep a view up to date.
  """
  @spec list(String.t()) :: [Member.t()]
  def list(prefix \\ "") when is_binary(prefix) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        String.starts_with?(key, prefix) do
      Member.new(key, pid, meta.user_meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Sends this process a message whenever an agent under `prefix` starts, stops,
  or changes what it is doing.

  Messages arrive as `{:group, [%Group.Event{}], info}`. A state change
  re-registers metadata, so a `:registered` event carrying `previous_meta` is a
  change rather than a new agent.

      Wardrik.Fleet.watch("acme/")
      Wardrik.Fleet.watch()        # the whole cluster
  """
  @spec watch(String.t()) :: :ok
  def watch(prefix \\ "") when is_binary(prefix), do: Group.monitor(@name, pattern(prefix))

  @doc "Stops the messages `watch/1` started."
  @spec unwatch(String.t()) :: :ok
  def unwatch(prefix \\ "") when is_binary(prefix), do: Group.demonitor(@name, pattern(prefix))

  defp pattern(""), do: :all
  defp pattern(prefix), do: prefix

  @doc """
  Interrupts every agent under `prefix`, and returns how many were told to stop.

  Each agent's turn is interrupted and its queue discarded; the agents stay up.
  Use `stop/1` or `forget/1` to be rid of one.
  """
  @spec kill(String.t()) :: non_neg_integer()
  def kill(prefix \\ "") when is_binary(prefix) do
    members = list(prefix)
    Enum.each(members, &Agent.interrupt(&1.pid))
    length(members)
  end
end
