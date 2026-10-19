defmodule WardrikDaemon.JudgeReplay do
  @moduledoc """
  A policy's judge tried on calls agents have made, as `wardrik policy judge`
  asks: what its model answers for each call now, what that decides, and how
  the call was decided when it was made. Nothing is decided or changed.

  The policy is read from its file as it is now, not as the daemon last read
  it, so its thresholds can be changed and tried again before a reload.

  The calls are those agents' logs keep with their arguments, which are the
  calls that ran (`tool_call.started`), read with `Wardrik.events/2` in the
  scope of whoever asks: a log keeps no arguments of a call refused, or of
  one still waiting on a person. Of those, the calls a question of the
  judge names, the newest first, each once however many times it ran.

  The judge is asked about each call as one of its agent's model calls on
  the host, so the host's dispatch admits it and its credentials hold the
  key, with no policy deciding it, as nothing is decided here.
  """

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Event.Log.Entry
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Scope
  alias WardrikDaemon.Agents
  alias WardrikPolicy.Judge

  @types ~w(wardrik.tool_call.started wardrik.interrupt.resolved)

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
    {files, _agents} =
      Agents.read_files(WardrikDaemon.Host.config(), host: WardrikDaemon.Host.get())

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
  @spec using(Wardrik.Definitions.t(), String.t()) :: [Wardrik.Resource.t()]
  def using(definitions, name) do
    for %Definition{id: id, policy: ^name} <-
          Wardrik.Definitions.list(definitions, Wardrik.Resource.parse!("*")),
        pattern <- of(id),
        do: pattern
  end

  @doc "The agent `id` with its threads: its resource, and what is under it."
  @spec of(Wardrik.AgentAddress.t()) :: [Wardrik.Resource.t()]
  def of(id) do
    itself = Wardrik.AgentAddress.resource(id)
    [itself, Wardrik.Resource.parse!("#{itself}/*")]
  end

  @doc """
  The newest `opts[:last]` calls the agents the patterns `opts[:under]`
  cover have kept, as `scope` reads them, that a question of `judge` names,
  each tried on it, newest first.
  """
  @spec tried(Scope.t(), Judge.t(), under: [Wardrik.Resource.t()], last: pos_integer()) ::
          [tried()]
  def tried(%Scope{} = scope, %Judge{} = judge, opts) do
    opts = Keyword.validate!(opts, [:under, :last])

    scope
    |> Wardrik.events!(resources: Keyword.fetch!(opts, :under), types: @types)
    |> calls(judge)
    |> Enum.sort_by(& &1.time, :desc)
    |> Enum.take(Keyword.fetch!(opts, :last))
    |> Task.async_stream(&judged(scope.host, judge, &1), timeout: :timer.minutes(2))
    |> Enum.map(fn {:ok, tried} -> tried end)
  end

  defp judged(host, judge, call) do
    run = Run.root(Config.new(), AgentID.address!(call.agent), name: "judge", host: host)
    answers = Judge.evaluate(judge, %{name: call.tool, arguments: call.arguments}, run: run)
    Map.merge(call, %{answers: answers, judged: Judge.judged(call.questions, answers)})
  end

  # Each call that ran whole, once, with who let it run where a person did.
  defp calls(entries, judge) do
    {started, resolved} =
      Enum.reduce(entries, {%{}, %{}}, fn %Entry{log: log, event: event}, {started, resolved} ->
        case event do
          %{"type" => "wardrik.tool_call.started", "data" => data} ->
            {Map.put_new(started, {log, data["tool"]["call"]["id"]}, {event, data}), resolved}

          %{"type" => "wardrik.interrupt.resolved", "data" => data} ->
            {started, Map.put(resolved, {log, data["interrupt"]["id"]}, data["resolved_by"])}

          _dropped ->
            {started, resolved}
        end
      end)

    for {{log, id} = key, {event, %{"tool" => %{"name" => tool, "call" => call}} = data}} <-
          started,
        not Map.get(call, "truncated", false),
        questions = Judge.asked(judge, tool),
        questions != [] do
      %{
        agent: to_string(log),
        id: id,
        time: event["time"],
        tool: tool,
        arguments: Map.get(call, "arguments", %{}),
        decided: put_resolver(data["decided"], resolved[key]),
        questions: questions
      }
    end
  end

  defp put_resolver(decided, nil), do: decided
  defp put_resolver(decided, by), do: Map.put(decided, "resolved_by", by)
end
