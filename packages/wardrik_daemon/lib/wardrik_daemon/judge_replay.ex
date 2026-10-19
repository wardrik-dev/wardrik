defmodule WardrikDaemon.JudgeReplay do
  @moduledoc """
  A policy's judge tried on calls agents have made, as `wardrik policy judge`
  asks: what its model answers for each call now, what that decides, and how
  the call was decided when it was made. Nothing is decided or changed.

  The policy is read from its file as it is now, not as the daemon last read
  it, so its thresholds can be changed and tried again before a reload.

  The calls are those agents' logs keep with their arguments, which are the
  calls that ran (`tool_call.started`): a log keeps no arguments of a call
  refused, or of one still waiting on a person. Of those, the calls a
  question of the judge names, the newest first, each once however many
  times it ran.

  The judge is asked about each call as one of its agent's model calls on
  the host, so the host's dispatch admits it and its credentials hold the
  key, with no policy deciding it, as nothing is decided here.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event.Log
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias WardrikDaemon.Agents
  alias WardrikDefinition.Record
  alias WardrikPolicy.Judge

  @page 500

  @typedoc """
  A call tried: where and when it ran, its tool as the agent knows it and its
  arguments, how it was decided then (`tool_call.started`'s `decided`, with
  `resolved_by` where a person did), the questions asked with each answer's
  probability or why there is none, and what the answers decide.
  """
  @type tried() :: %{
          agent: String.t(),
          id: String.t(),
          time: String.t(),
          tool: String.t(),
          arguments: map(),
          decided: map(),
          questions: [Judge.question()],
          answers: {:ok, [float()]} | {:error, term()},
          judged: Wardrik.Hook.decision() | {:allow, :judged}
        }

  @doc """
  The policy named `name` as its file reads now, with its judge, or why it
  has none.
  """
  @spec policy(String.t()) :: {:ok, WardrikPolicy.t()} | {:error, IO.chardata()}
  def policy(name) do
    {files, _agents} = Agents.read_files(WardrikDaemon.Host.config())

    case Enum.find(files, &named?(&1, name)) do
      {_path, {:ok, %WardrikPolicy{judge: nil}}} ->
        {:error,
         "The policy #{name} has no judge; give it a judge: section, with questions, to try one."}

      {_path, {:ok, policy}} ->
        {:ok, policy}

      {_path, {:error, message}} ->
        {:error, message}

      nil ->
        {:error, ["policies/ has no policy #{name}" | names(files)]}
    end
  end

  defp named?({_path, {:ok, policy}}, name), do: policy.name == name
  defp named?({path, {:error, _message}}, name), do: Path.rootname(Path.basename(path)) == name

  defp names(files) do
    case for {_path, {:ok, policy}} <- files, do: policy.name do
      [] -> []
      names -> ["; it has " | Enum.intersperse(names, ", ")]
    end
  end

  @doc """
  The agents a policy's calls are looked for under where none are named:
  each agent whose definition names the policy, with its conversations.
  """
  @spec using(WardrikStore.t(), String.t()) :: [Prefix.t()]
  def using(store, name) do
    for %Record{id: id, fields: %{"policy" => ^name}} <- Record.all(store),
        do: Prefix.of(id)
  end

  @doc """
  The newest `opts[:last]` calls kept in `host`'s store under the prefixes
  `opts[:under]` that a question of `judge` names, each tried on it, newest
  first.
  """
  @spec tried(Host.t(), Judge.t(), under: [Prefix.t()], last: pos_integer()) :: [tried()]
  def tried(%Host{} = host, %Judge{} = judge, opts) do
    opts = Keyword.validate!(opts, [:under, :last])
    prefixes = Keyword.fetch!(opts, :under)
    last = Keyword.fetch!(opts, :last)
    store = Host.store(host)

    for(
      log <- Log.logs(store),
      log != :audit,
      Enum.any?(prefixes, &Prefix.covers?(&1, log)),
      call <- calls(store, log, judge),
      do: call
    )
    |> Enum.sort_by(& &1.time, :desc)
    |> Enum.take(last)
    |> Task.async_stream(&judged(host, judge, &1), timeout: :timer.minutes(2))
    |> Enum.map(fn {:ok, tried} -> tried end)
  end

  defp judged(host, judge, call) do
    run = Run.root(Config.new(), AgentID.parse!(call.agent), name: "judge", host: host)
    answers = Judge.evaluate(run, judge, %{name: call.tool, arguments: call.arguments})
    Map.merge(call, %{answers: answers, judged: Judge.judged(call.questions, answers)})
  end

  # Each call of `log` that ran whole, once, with who let it run where a person did.
  defp calls(store, log, judge) do
    {started, resolved} =
      store
      |> events(log)
      |> Enum.reduce({%{}, %{}}, fn event, {started, resolved} ->
        case event do
          %{"type" => "wardrik.tool_call.started", "data" => data} ->
            {Map.put_new(started, data["tool"]["call"]["id"], {event, data}), resolved}

          %{"type" => "wardrik.interrupt.resolved", "data" => data} ->
            {started, Map.put(resolved, data["interrupt"]["id"], data["resolved_by"])}

          _other ->
            {started, resolved}
        end
      end)

    for {id, {event, %{"tool" => %{"name" => tool, "call" => call}} = data}} <- started,
        not Map.get(call, "truncated", false),
        questions = Judge.asked(judge, tool),
        questions != [] do
      %{
        agent: to_string(log),
        id: id,
        time: event["time"],
        tool: tool,
        arguments: Map.get(call, "arguments", %{}),
        decided: put_resolver(data["decided"], resolved[id]),
        questions: questions
      }
    end
  end

  defp put_resolver(decided, nil), do: decided
  defp put_resolver(decided, by), do: Map.put(decided, "resolved_by", by)

  # Every event `log` holds, a page at a time.
  defp events(store, log) do
    Stream.unfold(0, fn
      nil ->
        nil

      after_sequence ->
        case Log.read(store, log, starting_after: after_sequence, limit: @page) do
          {:ok, []} -> nil
          {:ok, events} when length(events) < @page -> {events, nil}
          {:ok, events} -> {events, String.to_integer(List.last(events)["sequence"])}
          {:gap, oldest} -> {[], oldest - 1}
        end
    end)
    |> Stream.concat()
  end
end
