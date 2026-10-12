defmodule WardrikSchedule do
  @moduledoc """
  A prompt an agent is asked on a clock.

      WardrikSchedule.put(~A"acme/triage", "sweep",
        every: "*/30 * * * *",
        prompt: "Check the incident queue.")

  Each schedule is a `DurableServer` keyed by the agent's ID and the
  schedule's name, so one process in the cluster owns it, and it carries on
  from its store on another node when its own is lost. When it comes due it
  calls `Wardrik.Agent.ask/2`, and announces what happened on the agent's topic
  as `Wardrik.Event.ScheduleFired`. It also joins a group of its agent's,
  so `for_agent/1` finds an agent's schedules by its ID rather than by
  looking through every schedule in the cluster.

  A schedule writes down its next run before it asks the agent, so a firing
  lost to a crash is not made again: a schedule fires at most once for each
  time it names.

  `sync/2` brings an agent's schedules to a list, starting, changing and
  deleting them, and `sync(agent, [])` deletes them all; what keeps the
  agent's definition calls it as that changes. The schedules run under a
  supervisor a host starts once per node, after Wardrik in its own tree:

      children = [Wardrik, WardrikSchedule]

  ## Options

    * `:every` - required. A five-field cron expression read in UTC, see
      `WardrikSchedule.Cron`; a duration of at least a minute, as `"30m"`,
      `"2h"` or `"1d"`; or `{:interval, ms}`
    * `:prompt` - required. What the agent is asked
    * `:overlap` - what a firing does when the agent is running or waiting
      on a person: `:skip`, the default, leaves it be, and `:queue` asks
      anyway, which the running turn takes at its next boundary
    * `:missed` - what a schedule that comes back overdue does, after its
      node or the daemon was down past a run: `:run_once`, the default, fires
      once and goes on from now, and `:skip` goes on from now
    * `:jitter` - up to this many milliseconds added to each run, `0` by
      default

  ## Outcomes

    * `:asked` - the agent was asked
    * `:busy` - the agent was running or waiting, and `overlap: :skip` left it
    * `:no_agent` - no agent runs under the ID
    * `:missed` - an overdue run that `missed: :skip` let go
    * `:failed` - asking the agent raised or exited
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikSchedule.Cron
  alias WardrikSchedule.Server
  alias WardrikSchedule.State
  alias WardrikSchedule.Status

  @enforce_keys [:name, :every, :prompt]
  defstruct [:name, :every, :prompt, overlap: :skip, missed: :run_once, jitter: 0]

  @typedoc "When a schedule runs: a cron expression's text, or every so many milliseconds."
  @type every() :: {:cron, String.t()} | {:interval, pos_integer()}

  @type t() :: %__MODULE__{
          name: String.t(),
          every: every(),
          prompt: String.t(),
          overlap: :skip | :queue,
          missed: :run_once | :skip,
          jitter: non_neg_integer()
        }

  @typedoc "What one firing did."
  @type outcome() :: :asked | :busy | :no_agent | :missed | :failed

  @name WardrikSchedule.Schedules
  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}
  @sizes Enum.sort_by(@units, &elem(&1, 1), :desc)

  @doc false
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc "The supervisor the schedules run under, started after Wardrik."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      DurableServer.Supervisor.child_spec(name: @name)
      | start: {__MODULE__, :start_link, [opts]}
    }

  @doc """
  Starts the supervisor the schedules run under, over the store the fleet
  runs on. `:log` is passed to `Group`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DurableServer.Supervisor.start_link(
      [
        name: @name,
        prefix: "schedules/",
        backend: WardrikStore.durable_backend(),
        group: [log: Keyword.get(opts, :log, false)]
      ] ++ WardrikStore.durable_shutdown()
    )
  end

  @doc """
  A schedule named `name`, from the options above. Raises `ArgumentError`
  on one that does not read.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts) when is_list(opts) do
    %__MODULE__{
      name: name!(name),
      every: every!(Keyword.get(opts, :every)),
      prompt: prompt!(Keyword.get(opts, :prompt)),
      overlap: one_of!(Keyword.get(opts, :overlap, :skip), [:skip, :queue], :overlap),
      missed: one_of!(Keyword.get(opts, :missed, :run_once), [:run_once, :skip], :missed),
      jitter: jitter!(Keyword.get(opts, :jitter, 0))
    }
  end

  defp name!(name) when is_binary(name) and name != "" do
    if String.contains?(name, "/"),
      do: raise(ArgumentError, "a schedule's name may not contain \"/\", got #{inspect(name)}"),
      else: name
  end

  defp name!(name),
    do: raise(ArgumentError, "a schedule's name is a string, got #{inspect(name)}")

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

  defp prompt!(prompt) when is_binary(prompt) and prompt != "", do: prompt
  defp prompt!(other), do: raise(ArgumentError, "prompt is a string, got #{inspect(other)}")

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

  @doc """
  A schedule named `name`, from fields written as text, as an agent file or a
  JSON body writes them:

      WardrikSchedule.decode("sweep", %{"every" => "*/30 * * * *", "prompt" => "Look.", "overlap" => "queue"})

  `every` and `prompt` are as `new/2` takes them, `overlap` is `skip` or
  `queue`, `missed` is `run_once` or `skip`, and `jitter` is whole seconds.
  """
  @spec decode(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def decode(name, fields) when is_map(fields) do
    with :ok <- known(fields),
         {:ok, every} <- every(fields["every"]),
         {:ok, overlap} <- choice(fields, "overlap", :skip, ~w(skip queue)),
         {:ok, missed} <- choice(fields, "missed", :run_once, ~w(run_once skip)),
         {:ok, jitter} <- seconds(fields["jitter"]) do
      {:ok,
       new(name,
         every: every,
         prompt: fields["prompt"],
         overlap: overlap,
         missed: missed,
         jitter: jitter
       )}
    end
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  @fields ~w(every prompt overlap missed jitter)

  defp known(fields) do
    case Map.keys(fields) -- @fields do
      [] ->
        :ok

      [key | _] ->
        {:error, "#{key} is not a setting; expected every, prompt, overlap, missed or jitter"}
    end
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
  `schedule` written as text, with its name, as `decode/2` reads it back:

      %{"name" => "sweep", "every" => "30m", "prompt" => "Look.",
        "overlap" => "skip", "missed" => "run_once", "jitter" => 0}

  An interval is written in the largest unit that divides it.
  """
  @spec encode(t()) :: %{String.t() => String.t() | non_neg_integer()}
  def encode(%__MODULE__{} = schedule) do
    %{
      "name" => schedule.name,
      "every" => text(schedule.every),
      "prompt" => schedule.prompt,
      "overlap" => to_string(schedule.overlap),
      "missed" => to_string(schedule.missed),
      "jitter" => div(schedule.jitter, 1_000)
    }
  end

  defp text({:cron, text}), do: text

  defp text({:interval, ms}) do
    {unit, size} = Enum.find(@sizes, fn {_unit, size} -> rem(ms, size) == 0 end)
    "#{div(ms, size)}#{unit}"
  end

  @doc """
  The first time `schedule` names after `from`, with its jitter added.
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
  Starts `schedule` for the agent `agent`, or brings a running one to
  it. A schedule whose `every` changes goes on from now; one that keeps it
  keeps its next run.
  """
  @spec put(AgentID.t(), t()) :: {:ok, pid()} | {:error, term()}
  def put(%AgentID{} = agent, %__MODULE__{} = schedule) do
    child =
      {Server, key: key(agent, schedule.name), initial_state: State.new(agent, schedule, now())}

    with {:ok, {pid, _meta}} <- DurableServer.Supervisor.ensure_started_child(@name, child),
         :ok <- GenServer.call(pid, {:configure, schedule}) do
      {:ok, pid}
    end
  end

  @doc "`put/2` with `new/2`'s arguments."
  @spec put(AgentID.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def put(agent, name, opts), do: put(agent, new(name, opts))

  @doc "Stops the schedule named `name` for `agent`, and deletes it."
  @spec delete(AgentID.t(), String.t()) :: :ok | {:error, term()}
  def delete(%AgentID{} = agent, name) when is_binary(name) do
    DurableServer.Supervisor.terminate_and_delete_child(@name, key(agent, name))
  end

  @doc """
  Brings `agent`'s schedules to `schedules`: each is put, and every other
  schedule the agent has is deleted.
  """
  @spec sync(AgentID.t(), [t()]) :: :ok | {:error, term()}
  def sync(%AgentID{} = agent, schedules) when is_list(schedules) do
    names = MapSet.new(schedules, & &1.name)

    with :ok <- put_all(agent, schedules) do
      agent
      |> for_agent()
      |> Enum.reject(&(&1.name in names))
      |> Enum.each(&delete(agent, &1.name))
    end
  end

  defp put_all(agent, schedules) do
    Enum.reduce_while(schedules, :ok, fn schedule, :ok ->
      case put(agent, schedule) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:schedule, schedule.name, reason}}}
      end
    end)
  end

  @doc "The schedules of `agent`, by name."
  @spec for_agent(AgentID.t()) :: [Status.t()]
  def for_agent(%AgentID{} = agent) do
    for {_pid, %{name: name}} <- Group.members(@name, group(agent)),
        key = key(agent, name),
        {pid, meta} <- [DurableServer.Supervisor.lookup(@name, key)] do
      Status.new(key, pid, meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  @doc false
  @spec join(AgentID.t(), String.t()) :: :ok
  def join(%AgentID{} = agent, name), do: Group.join(@name, group(agent), %{name: name})

  defp group(agent), do: "agents/#{agent}"

  @doc "Every schedule of the agents under `prefix`, across the cluster, sorted by key."
  @spec list(Prefix.t()) :: [Status.t()]
  def list(prefix \\ Prefix.all()) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        Prefix.covers?(prefix, meta.user_meta.agent) do
      Status.new(key, pid, meta.user_meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  # `//` holds no ID, so an agent's schedules never mix with those of an agent
  # whose external ID is one of its schedules' names.
  defp key(agent, name), do: "#{agent}//#{name}"

  defp now, do: DateTime.utc_now()
end
