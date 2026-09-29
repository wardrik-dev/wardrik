defmodule Wardrik.Schedule do
  @moduledoc """
  A prompt an agent is asked on a clock.

      Wardrik.Schedule.put("acme/ops/triage", "sweep",
        every: "*/30 * * * *",
        prompt: "Check the incident queue.")

  Each schedule is a `DurableServer` keyed by the agent's key and the
  schedule's name, so one process in the cluster owns it, and it carries on
  from its store on another node when its own is lost. When it comes due it
  calls `Wardrik.Agent.ask/2`, and announces what happened on the agent's topic
  as `{:schedule_fired, name, outcome}`.

  A schedule writes down its next run before it asks the agent, so a firing
  lost to a crash is not made again: a schedule fires at most once for each
  time it names.

  `Wardrik.Agent.Spec` carries an agent's schedules, and `Wardrik.Fleet.put/1`
  brings them to what the spec says, starting, changing and deleting them.
  `Wardrik.Fleet.forget/1` deletes an agent's schedules with it.

  ## Options

    * `:every` - required. A five-field cron expression read in UTC, see
      `Wardrik.Schedule.Cron`; a duration of at least a minute, as `"30m"`,
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
    * `:no_agent` - no agent runs under the key
    * `:missed` - an overdue run that `missed: :skip` let go
    * `:failed` - asking the agent raised or exited
  """

  alias Wardrik.Schedule.Cron
  alias Wardrik.Schedule.Server
  alias Wardrik.Schedule.State
  alias Wardrik.Schedule.Status

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

  @name Wardrik.Schedules
  @prefix "schedules/"
  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}

  @doc false
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

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

      Wardrik.Schedule.decode("sweep", %{"every" => "*/30 * * * *", "prompt" => "Look.", "overlap" => "queue"})

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
  Starts `schedule` for the agent under `agent`, or brings a running one to
  it. A schedule whose `every` changes goes on from now; one that keeps it
  keeps its next run.
  """
  @spec put(String.t(), t()) :: {:ok, pid()} | {:error, term()}
  def put(agent, %__MODULE__{} = schedule) when is_binary(agent) do
    child =
      {Server, key: key(agent, schedule.name), initial_state: State.new(agent, schedule, now())}

    with {:ok, {pid, _meta}} <- DurableServer.Supervisor.ensure_started_child(@name, child),
         :ok <- GenServer.call(pid, {:configure, schedule}) do
      {:ok, pid}
    end
  end

  @doc "`put/2` with `new/2`'s arguments."
  @spec put(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def put(agent, name, opts), do: put(agent, new(name, opts))

  @doc "Stops the schedule named `name` for `agent`, and deletes it."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent, name) when is_binary(agent) and is_binary(name) do
    DurableServer.Supervisor.terminate_and_delete_child(@name, key(agent, name))
  end

  @doc """
  Brings `agent`'s schedules to `schedules`: each is put, and every other
  schedule the agent has is deleted.
  """
  @spec sync(String.t(), [t()]) :: :ok | {:error, term()}
  def sync(agent, schedules) when is_binary(agent) and is_list(schedules) do
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

  @doc "The schedules of the agent under `agent`, by name."
  @spec for_agent(String.t()) :: [Status.t()]
  def for_agent(agent) when is_binary(agent), do: list(agent <> "/")

  @doc "Every schedule whose key starts with `prefix`, across the cluster, sorted by key."
  @spec list(String.t()) :: [Status.t()]
  def list(prefix \\ "") when is_binary(prefix) do
    for {key, {pid, meta}} <- DurableServer.Supervisor.global_members(@name),
        String.starts_with?(key, prefix) do
      Status.new(key, pid, meta.user_meta)
    end
    |> Enum.sort_by(& &1.key)
  end

  defp key(agent, name), do: agent <> "/" <> name

  defp now, do: DateTime.utc_now()
end
