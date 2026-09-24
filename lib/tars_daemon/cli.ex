defmodule TarsDaemon.CLI do
  @moduledoc """
  What `bin/tars` asks a running daemon. `main/1` runs one command on the
  daemon's node and prints its answer; a command that fails prints why and
  exits with status 1.

  | Command | Answer |
  | --- | --- |
  | `status` | the node, its cluster, its agents, and each file that does not read |
  | `reload` | reads the agent and policy files again on every node of the cluster, then answers as `status` |
  | `ask KEY MESSAGE` | sends the agent a message, which it answers in a turn of its own |
  | `history KEY` | the agent's conversation, one message a paragraph |
  | `parked` | every call an agent is waiting on a person for |
  | `schedules [PREFIX]` | every schedule, or those whose key starts with `PREFIX`: when it runs next, and when it last ran and what came of it |
  | `approve KEY CALL` | runs the call, and the agent carries on |
  | `deny KEY CALL [REASON]` | refuses the call, telling the agent why |

  A node waiting for a quorum of its cluster answers every command with what
  it is waiting for; see `TarsDaemon.Cluster.waiting/0`.
  """

  alias Tars.Agent
  alias Tars.Fleet
  alias TarsDaemon.Cluster
  alias TarsPolicy.Pattern

  @doc """
  What `tars start` waits for: `""` once the agent files have been read, what
  the node is waiting for where it is waiting for its cluster, and a raise
  before either, or for a node the cluster does not name, which stops.
  """
  @spec started() :: String.t()
  def started do
    cond do
      Process.whereis(TarsDaemon.Agents) ->
        _files = TarsDaemon.Agents.files()
        ""

      reason = Cluster.refusal() ->
        raise reason

      reason = Cluster.waiting() ->
        reason

      true ->
        raise "tars is starting"
    end
  end

  @doc """
  What `tars stop` asks first: `""` where the node stops the usual way,
  writing down what it holds. A node that has lost its cluster's quorum can
  write down nothing, so it halts at once instead, as a node that crashed
  does, and the answer says so.
  """
  @spec stopping() :: String.t()
  def stopping do
    case Cluster.waiting() do
      nil ->
        ""

      reason ->
        {:ok, _timer} = :timer.apply_after(100, System, :halt, [0])

        reason <> ", so it can write down nothing it holds, and stops at once"
    end
  end

  @doc "Runs the command `args` names."
  @spec main([String.t()]) :: :ok
  def main(args) do
    case Cluster.waiting() do
      nil -> run(args)
      reason -> if args == ["status"], do: ok(reason), else: fail(reason)
    end
  end

  defp run(["status"]), do: ok(TarsDaemon.status())

  defp run(["reload"]) do
    for daemon <- daemons(),
        do: :erpc.call(daemon, TarsDaemon.Agents, :reload, [], :timer.minutes(1))

    ok(TarsDaemon.status())
  end

  defp run(["ask", key | words]) when words != [] do
    case Agent.ask(key, Enum.join(words, " ")) do
      :ok -> ok("Asked #{key}.")
      {:error, :not_found} -> fail("No agent runs under #{key}.")
    end
  end

  defp run(["history", key]) do
    case Agent.get_context(key) do
      {:error, :not_found} -> fail("No agent runs under #{key}.")
      context -> ok(history(context))
    end
  end

  defp run(["parked"]), do: ok(parked())
  defp run(["schedules"]), do: ok(schedules(""))
  defp run(["schedules", prefix]), do: ok(schedules(prefix))
  defp run(["approve", key, call]), do: decide(key, call, :approve, "Approved")

  defp run(["deny", key, call | reason]) do
    reason = if reason == [], do: "A person refused this call.", else: Enum.join(reason, " ")
    decide(key, call, {:deny, reason}, "Denied")
  end

  defp run(args), do: fail("tars: no command #{Enum.join(args, " ")}")

  # This node and every node connected to it that runs a daemon of its own.
  defp daemons do
    for daemon <- [node() | Node.list()],
        :erpc.call(daemon, Process, :whereis, [TarsDaemon.Agents]) != nil,
        do: daemon
  end

  defp history(context) do
    case ReqLLM.Context.to_list(context) do
      [] -> "Nothing has been said yet."
      messages -> Enum.map_join(messages, "\n\n", &message/1)
    end
  end

  defp message(%{role: role} = message), do: "#{role}: #{text(message)}"

  defp text(%{content: content}) when is_binary(content), do: content

  defp text(%{content: parts} = message) when is_list(parts) do
    written = for %{type: :text, text: text} <- parts, do: text

    calls =
      for call <- Map.get(message, :tool_calls) || [],
          do: "[calls #{Pattern.shown(ReqLLM.ToolCall.name(call))}]"

    Enum.join(written ++ calls, " ")
  end

  defp parked do
    rows =
      for %{status: :parked, key: key} <- Fleet.list(),
          {call, prompt} <- waiting(key),
          do: "  #{key}  #{call.id}  #{Pattern.shown(call.name)}  #{prompt}"

    case rows do
      [] -> "Nothing is waiting on a person."
      rows -> Enum.join(["#{length(rows)} waiting:" | rows], "\n")
    end
  end

  defp schedules(prefix) do
    now = DateTime.utc_now()

    rows =
      for schedule <- Tars.Schedule.list(prefix) do
        next = TarsDaemon.duration(max(DateTime.diff(schedule.next_at, now, :millisecond), 0))
        "  #{schedule.key}  #{every(schedule.every)}  next in #{next}  #{last(schedule, now)}"
      end

    case rows do
      [] -> "Nothing is scheduled#{if prefix != "", do: " under #{prefix}"}."
      [_row] -> Enum.join(["1 schedule:" | rows], "\n")
      rows -> Enum.join(["#{length(rows)} schedules:" | rows], "\n")
    end
  end

  defp every({:cron, text}), do: text
  defp every({:interval, ms}), do: "every " <> interval(ms)

  defp interval(ms) when rem(ms, 86_400_000) == 0, do: "#{div(ms, 86_400_000)}d"
  defp interval(ms) when rem(ms, 3_600_000) == 0, do: "#{div(ms, 3_600_000)}h"
  defp interval(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp interval(ms), do: "#{ms}ms"

  defp last(%{last_at: nil, last_outcome: nil}, _now), do: "not run yet"
  defp last(%{last_at: nil, last_outcome: outcome}, _now), do: "last: " <> outcome(outcome)

  defp last(%{last_at: at, last_outcome: outcome}, now) do
    ago = TarsDaemon.duration(max(DateTime.diff(now, at, :millisecond), 0))
    "last run #{ago} ago: " <> outcome(outcome)
  end

  defp outcome(nil), do: "asking"
  defp outcome(:asked), do: "asked"
  defp outcome(:busy), do: "skipped, the agent was busy"
  defp outcome(:no_agent), do: "no agent runs under the key"
  defp outcome(:missed), do: "let a missed run go"
  defp outcome(:failed), do: "failed to ask"

  defp waiting(key) do
    case Agent.parked(key) do
      calls when is_list(calls) -> calls
      {:error, :not_found} -> []
    end
  end

  # `bin/tars` reaches the node with its cookie, which only the account the
  # node runs as can read, so that account is who decides.
  defp decide(key, call, decision, done) do
    by = %Tars.Principal{type: :shell, id: System.get_env("USER") || "unknown"}

    case Agent.decide(key, %{call => decision}, by: by) do
      :ok -> ok("#{done} #{call} for #{key}.")
      {:error, :not_found} -> fail("No agent runs under #{key}.")
      {:error, :not_parked} -> fail("#{key} is not waiting on anything.")
      {:error, :stale_decision} -> fail("#{key} is not waiting on #{call}.")
    end
  end

  defp ok(text), do: IO.puts(text)

  defp fail(text) do
    IO.puts(text)
    exit({:shutdown, 1})
  end
end
