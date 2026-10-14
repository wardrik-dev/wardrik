defmodule WardrikTrigger do
  @moduledoc """
  A prompt an agent is asked when its time comes: on a clock, or when a
  source it watches finds something new.

      WardrikTrigger.put(~A"acme/triage", "sweep",
        every: "*/30 * * * *",
        prompt: "Check the incident queue.")

  Each trigger is a `DurableServer` keyed by the agent's ID and the
  trigger's name, so one process in the cluster owns it, and it carries on
  from its store on another node when its own is lost. When it comes due it
  checks its source, and where that found something calls
  `Wardrik.Agent.ask/3`, and it announces what happened on the agent's topic
  as `Wardrik.Event.TriggerFired`. It also joins a group of its agent's,
  so `for_agent/1` finds an agent's triggers by its ID rather than by
  looking through every trigger in the cluster.

  A trigger writes down its next run before it asks the agent, so a firing
  lost to a crash is not made again: a trigger fires at most once for each
  time it names.

  ## Sources

  A trigger watches a `WardrikTrigger.Source`: the clock, which asks the
  agent its prompt on every run, unless it names another, which asks only
  when it finds something new, with what it found under the prompt:

      WardrikTrigger.put(~A"acme/growth", "mentions",
        every: "1h",
        prompt: "New mentions of Acme. Which deserve a reply?",
        source: {MyApp.Feed, "https://example.com/alerts.xml"})

  A source registers the key a trigger written as text names it by, so
  `decode/2` reads it; see `WardrikTrigger.Source`.

  ## Webhooks

  A trigger that a service sends requests is a `WardrikTrigger.Webhook`, a
  kind of its own: it has no clock, and asks its agent as each request
  arrives, through `deliver/3`, which makes this module the host's
  `Wardrik.Triggers`. `decode/2`, `put/2`, `sync/2` and the listings take
  every kind alike, through `WardrikTrigger.Kind`. The secrets a webhook is checked with are read for its agent
  by the host's `:secrets`, so each org can keep its own, and from the
  environment where the host gives none:

      children = [
        {WardrikStore, store},
        {Wardrik, host: host},
        {WardrikTrigger, store: store, secrets: &MyApp.Vault.secret/2}
      ]

  `sync/2` brings an agent's triggers to a list, starting, changing and
  deleting them, and `sync(agent, [])` deletes them all; what keeps the
  agent's definition calls it as that changes. The triggers run under a
  supervisor a host starts once per node, after Wardrik in its own tree:

      children = [Wardrik, WardrikTrigger]

  ## Options

    * `:every` - required. A five-field cron expression read in UTC, see
      `WardrikTrigger.Cron`; a duration of at least a minute, as `"30m"`,
      `"2h"` or `"1d"`; or `{:interval, ms}`
    * `:prompt` - required. What the agent is asked
    * `:overlap` - what a firing does when the agent is running or waiting
      on a person: `:skip`, the default, leaves it be, and `:queue` asks
      anyway, which the running turn takes at its next boundary
    * `:missed` - what a trigger that comes back overdue does, after its
      node or the daemon was down past a run: `:run_once`, the default, fires
      once and goes on from now, and `:skip` goes on from now
    * `:jitter` - up to this many milliseconds added to each run, `0` by
      default
    * `:source` - what it watches, as `{module, opts}` of a
      `WardrikTrigger.Source`; the clock, `{WardrikTrigger.Clock, nil}`, by
      default

  ## Outcomes

    * `:asked` - the agent was asked
    * `:nothing_new` - the source found nothing, so the agent was not asked
    * `:busy` - the agent was running or waiting, and `overlap: :skip` left it
    * `:no_agent` - no agent runs under the ID
    * `:missed` - an overdue run that `missed: :skip` let go
    * `:failed` - the source could not be checked, or asking the agent
      raised or exited
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikTrigger.Clock
  alias WardrikTrigger.Cron
  alias WardrikTrigger.Kind
  alias WardrikTrigger.Source
  alias WardrikTrigger.Status
  alias WardrikTrigger.Webhook

  @enforce_keys [:name, :every, :prompt]
  defstruct [
    :name,
    :every,
    :prompt,
    overlap: :skip,
    missed: :run_once,
    jitter: 0,
    source: {Clock, nil}
  ]

  @typedoc "When a trigger runs: a cron expression's text, or every so many milliseconds."
  @type every() :: {:cron, String.t()} | {:interval, pos_integer()}

  @type t() :: %__MODULE__{
          name: String.t(),
          every: every(),
          prompt: String.t(),
          overlap: :skip | :queue,
          missed: :run_once | :skip,
          jitter: non_neg_integer(),
          source: {module(), term()}
        }

  @typedoc "A trigger of either kind: on a clock, or a webhook."
  @type trigger() :: t() | Webhook.t()

  @typedoc "What one firing did."
  @type outcome() :: :asked | :nothing_new | :busy | :no_agent | :missed | :failed

  @name WardrikTrigger.Triggers
  @fields ~w(every prompt overlap missed jitter)
  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}
  @sizes Enum.sort_by(@units, &elem(&1, 1), :desc)

  @doc false
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc "The supervisor the triggers run under, started after Wardrik."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      DurableServer.Supervisor.child_spec(name: @name)
      | start: {__MODULE__, :start_link, [opts]}
    }

  @doc """
  Starts the supervisor the triggers run under, over the store the fleet
  runs on, which `:store` names. `:log` is passed to `Group`. A request for
  a webhook reaches it through `WardrikTrigger.Deliveries`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DurableServer.Supervisor.start_link(
      [
        name: @name,
        prefix: "triggers/",
        backend: opts |> Keyword.fetch!(:store) |> WardrikStore.durable_backend(),
        group: [log: Keyword.get(opts, :log, false)]
      ] ++ WardrikStore.durable_shutdown()
    )
  end

  @doc """
  A trigger named `name`, from the options above. Raises `ArgumentError`
  on one that does not read.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts) when is_list(opts) do
    %__MODULE__{
      name: name!(name),
      every: every!(Keyword.get(opts, :every)),
      prompt: prompt!(Keyword.get(opts, :prompt)),
      overlap: overlap!(Keyword.get(opts, :overlap, :skip)),
      missed: one_of!(Keyword.get(opts, :missed, :run_once), [:run_once, :skip], :missed),
      jitter: jitter!(Keyword.get(opts, :jitter, 0)),
      source: source!(Keyword.get(opts, :source, {Clock, nil}))
    }
  end

  @doc false
  @spec name!(term()) :: String.t()
  def name!(name) when is_binary(name) and name != "" do
    if String.contains?(name, "/"),
      do: raise(ArgumentError, "a trigger's name may not contain \"/\", got #{inspect(name)}"),
      else: name
  end

  def name!(name),
    do: raise(ArgumentError, "a trigger's name is a string, got #{inspect(name)}")

  defp every!({:interval, ms} = every) when is_integer(ms) and ms > 0, do: every

  defp every!({:cron, text}) when is_binary(text), do: every!(text)

  defp every!(text) when is_binary(text) do
    case Regex.run(~r/^\s*(\d+)\s*([smhd])\s*$/, text) do
      [_, n, unit] ->
        interval!(String.to_integer(n) * Map.fetch!(@units, unit), text)

      nil ->
        case Cron.parse(text) do
          {:ok, cron} -> {:cron, cron.source}
          {:error, message} -> raise ArgumentError, "every: #{message}"
        end
    end
  end

  defp every!(other) do
    raise ArgumentError,
          "every is a cron expression, a duration such as \"30m\", or {:interval, ms}, " <>
            "got #{inspect(other)}"
  end

  defp interval!(ms, text) when ms < 60_000,
    do: raise(ArgumentError, "every: #{inspect(text)} is shorter than a minute")

  defp interval!(ms, _text), do: {:interval, ms}

  @doc false
  @spec prompt!(term()) :: String.t()
  def prompt!(prompt) when is_binary(prompt) and prompt != "", do: prompt
  def prompt!(other), do: raise(ArgumentError, "prompt is a string, got #{inspect(other)}")

  @doc false
  @spec overlap!(term()) :: :skip | :queue
  def overlap!(overlap), do: one_of!(overlap, [:skip, :queue], :overlap)

  defp one_of!(value, allowed, key) do
    if value in allowed,
      do: value,
      else:
        raise(
          ArgumentError,
          "#{key} is one of #{Enum.map_join(allowed, ", ", &inspect/1)}, got #{inspect(value)}"
        )
  end

  defp jitter!(ms) when is_integer(ms) and ms >= 0, do: ms
  defp jitter!(other), do: raise(ArgumentError, "jitter is milliseconds, got #{inspect(other)}")

  defp source!({module, _opts} = source) when is_atom(module), do: source

  defp source!(other),
    do: raise(ArgumentError, "source is {module, opts}, got #{inspect(other)}")

  @doc """
  A trigger named `name`, from fields written as text, as an agent file or a
  JSON body writes them:

      WardrikTrigger.decode("sweep", %{"every" => "*/30 * * * *", "prompt" => "Look.", "overlap" => "queue"})

  `every` and `prompt` are as `new/2` takes them, `overlap` is `skip` or
  `queue`, `missed` is `run_once` or `skip`, and `jitter` is whole seconds.
  The fields left are the source's, which one of them names by its key, and
  the clock's where none does: see `WardrikTrigger.Source`. Fields with
  `webhook` are a `WardrikTrigger.Webhook`'s, which `Webhook.decode/2` reads.
  """
  @spec decode(String.t(), map()) :: {:ok, trigger()} | {:error, String.t()}
  def decode(name, %{"webhook" => _own} = fields), do: Webhook.decode(name, fields)

  def decode(name, fields) when is_map(fields) do
    {own, rest} = Map.split(fields, @fields)

    with {:ok, source} <- source(rest),
         {:ok, every} <- every(own["every"]),
         {:ok, overlap} <- choice(own, "overlap", :skip, ~w(skip queue)),
         {:ok, missed} <- choice(own, "missed", :run_once, ~w(run_once skip)),
         {:ok, jitter} <- seconds(own["jitter"]) do
      {:ok,
       new(name,
         every: every,
         prompt: own["prompt"],
         overlap: overlap,
         missed: missed,
         jitter: jitter,
         source: source
       )}
    end
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  @doc """
  The fields a trigger written as text may have: those every trigger has,
  the key of each source a loaded application registers, and a webhook's.
  """
  @spec keys() :: [String.t()]
  def keys, do: @fields ++ Enum.sort(["webhook" | Map.keys(Source.all())])

  defp source(fields) do
    sources = Source.all()

    case fields |> Map.keys() |> Enum.filter(&Map.has_key?(sources, &1)) |> Enum.sort() do
      [] -> clock(fields)
      [key] -> source(Map.fetch!(sources, key), fields)
      [one, other | _] -> {:error, "#{one} and #{other} each name a source; a trigger has one"}
    end
  end

  defp source(module, fields) do
    with {:ok, opts} <- module.decode(fields), do: {:ok, {module, opts}}
  end

  defp clock(fields) when map_size(fields) == 0, do: {:ok, {Clock, nil}}

  defp clock(fields) do
    {last, others} = List.pop_at(keys(), -1)

    {:error,
     IO.iodata_to_binary([
       fields |> Map.keys() |> Enum.min(),
       " is not a setting; expected ",
       Enum.intersperse(others, ", "),
       " or ",
       last
     ])}
  end

  defp every(text) when is_binary(text), do: {:ok, text}
  defp every(_other), do: {:error, "every is a cron expression, or a duration such as \"30m\""}

  defp choice(fields, key, default, allowed) do
    case Map.get(fields, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in allowed,
          do: {:ok, String.to_existing_atom(value)},
          else: choices(key, allowed)

      _other ->
        choices(key, allowed)
    end
  end

  defp choices(key, allowed), do: {:error, "#{key} is one of #{Enum.join(allowed, ", ")}"}

  defp seconds(nil), do: {:ok, 0}

  defp seconds(seconds) when is_integer(seconds) and seconds >= 0,
    do: {:ok, :timer.seconds(seconds)}

  defp seconds(_seconds), do: {:error, "jitter is a whole number of seconds"}

  @doc """
  `trigger` written as text, with its name, as `decode/2` reads it back:

      %{"name" => "sweep", "every" => "30m", "prompt" => "Look.",
        "overlap" => "skip", "missed" => "run_once", "jitter" => 0}

  An interval is written in the largest unit that divides it, and the
  source's fields are written beside the rest. A webhook is written as
  `Webhook.encode/1` writes it.
  """
  @spec encode(trigger()) :: %{String.t() => term()}
  def encode(trigger), do: Kind.encode(trigger)

  @doc false
  @spec written(every()) :: String.t()
  def written({:cron, text}), do: text

  def written({:interval, ms}) do
    {unit, size} = Enum.find(@sizes, fn {_unit, size} -> rem(ms, size) == 0 end)
    "#{div(ms, size)}#{unit}"
  end

  @doc "What `trigger`'s source finds for `agent` since `cursor`; see `WardrikTrigger.Source`."
  @spec check(t(), Source.cursor() | nil, AgentID.t()) ::
          {:ok, [WardrikTrigger.Item.t()], Source.cursor()} | {:error, String.t()}
  def check(%__MODULE__{source: {module, opts}}, cursor, %AgentID{} = agent),
    do: module.check(opts, cursor, agent)

  @doc "When `every` runs, as a person reads it: the cron expression, or `every 30m`."
  @spec schedule(every()) :: String.t()
  def schedule({:cron, text}), do: text
  def schedule({:interval, ms} = every) when rem(ms, 1_000) == 0, do: "every " <> written(every)
  def schedule({:interval, ms}), do: "every #{ms}ms"

  @doc false
  @spec lookup(AgentID.t(), String.t()) :: pid() | nil
  def lookup(%AgentID{} = agent, name) when is_binary(name) do
    case DurableServer.Supervisor.lookup(@name, Webhook.key(agent, name)) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc """
  The first time `trigger` names after `from`, with its jitter added.
  """
  @spec next(t(), DateTime.t()) :: DateTime.t()
  def next(%__MODULE__{every: every, jitter: jitter}, %DateTime{} = from) do
    at =
      case every do
        {:interval, ms} ->
          DateTime.add(from, ms, :millisecond)

        {:cron, text} ->
          {:ok, cron} = Cron.parse(text)
          {:ok, at} = Cron.next(cron, from)
          at
      end

    if jitter > 0, do: DateTime.add(at, :rand.uniform(jitter + 1) - 1, :millisecond), else: at
  end

  @doc """
  Starts `trigger` for the agent `agent`, or brings a running one to
  it. A trigger whose `every` changes goes on from now; one that keeps it
  keeps its next run. A trigger of another kind under the same name is
  deleted.
  """
  @spec put(AgentID.t(), trigger()) :: {:ok, pid()} | {:error, term()}
  def put(%AgentID{} = agent, trigger) do
    key = Kind.key(trigger, agent)
    {server, initial} = Kind.child(trigger, agent)
    child = {server, key: key, initial_state: initial}

    with {:ok, {pid, _meta}} <- DurableServer.Supervisor.ensure_started_child(@name, child),
         :ok <- GenServer.call(pid, {:configure, trigger}) do
      for %{name: name, key: other} <- for_agent(agent),
          name == trigger.name,
          other != key,
          do: terminate(other)

      {:ok, pid}
    end
  end

  @doc "`put/2` with `new/2`'s arguments."
  @spec put(AgentID.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def put(agent, name, opts), do: put(agent, new(name, opts))

  @doc "Stops the trigger named `name` for `agent`, of whichever kind, and deletes it."
  @spec delete(AgentID.t(), String.t()) :: :ok | {:error, term()}
  def delete(%AgentID{} = agent, name) when is_binary(name) do
    agent
    |> for_agent()
    |> Enum.filter(&(&1.name == name))
    |> Enum.reduce_while(:ok, fn status, :ok ->
      case terminate(status.key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp terminate(key), do: DurableServer.Supervisor.terminate_and_delete_child(@name, key)

  @doc """
  Brings `agent`'s triggers to `triggers`: each is put, and every other
  trigger the agent has is deleted.
  """
  @spec sync(AgentID.t(), [trigger()]) :: :ok | {:error, term()}
  def sync(%AgentID{} = agent, triggers) when is_list(triggers) do
    keys = MapSet.new(triggers, &Kind.key(&1, agent))

    with :ok <- put_all(agent, triggers) do
      agent
      |> for_agent()
      |> Enum.reject(&(&1.key in keys))
      |> Enum.each(&terminate(&1.key))
    end
  end

  defp put_all(agent, triggers) do
    Enum.reduce_while(triggers, :ok, fn trigger, :ok ->
      case put(agent, trigger) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:trigger, trigger.name, reason}}}
      end
    end)
  end

  @doc "The triggers of `agent`, by name."
  @spec for_agent(AgentID.t()) :: [Status.t()]
  def for_agent(%AgentID{} = agent) do
    for {_pid, %{key: key}} <- Group.members(@name, group(agent)),
        {pid, meta} <- [DurableServer.Supervisor.lookup(@name, key)] do
      Status.new(key, pid, meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  @doc "Joins `trigger`'s process to `agent`'s triggers, as `for_agent/1` finds them."
  @spec join(AgentID.t(), trigger()) :: :ok
  def join(%AgentID{} = agent, trigger),
    do: Group.join(@name, group(agent), %{key: Kind.key(trigger, agent)})

  defp group(agent), do: "agents/#{agent}"

  @doc "Every trigger of the agents under `prefix`, across the cluster, sorted by key."
  @spec list(Prefix.t()) :: [Status.t()]
  def list(prefix \\ Prefix.all()) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        Prefix.covers?(prefix, meta.user_meta.agent) do
      Status.new(key, pid, meta.user_meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  @doc false
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()
end

defimpl WardrikTrigger.Kind, for: WardrikTrigger do
  # `//` holds no ID, so an agent's triggers never mix with those of an agent
  # whose external ID is one of its triggers' names.
  def key(trigger, agent), do: "#{agent}//#{trigger.name}"

  def child(trigger, agent),
    do: {WardrikTrigger.Server, WardrikTrigger.State.new(agent, trigger, WardrikTrigger.now())}

  def encode(%WardrikTrigger{source: {module, opts}} = trigger) do
    opts
    |> module.encode()
    |> Map.merge(%{
      "name" => trigger.name,
      "every" => WardrikTrigger.written(trigger.every),
      "prompt" => trigger.prompt,
      "overlap" => to_string(trigger.overlap),
      "missed" => to_string(trigger.missed),
      "jitter" => div(trigger.jitter, 1_000)
    })
  end
end
