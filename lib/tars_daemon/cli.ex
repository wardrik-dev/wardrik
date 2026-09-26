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
  | `token create NAME --scope PREFIX` | a token for the HTTP API that reaches the agents under `PREFIX`, printed once. `PREFIX` is `org/`, `org/user/`, or a key, `org/user/name` |
  | `token create NAME --all` | a token that reaches every agent |
  | `token list` | every token: its id, name and scope |
  | `token revoke ID` | stops the token working |

  A node waiting for a quorum of its cluster answers every command with what
  it is waiting for; see `TarsDaemon.Cluster.waiting/0`.
  """

  alias Tars.Agent
  alias Tars.Fleet
  alias Tars.Grant
  alias TarsDaemon.Cluster
  alias TarsHTTP.Token
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

  defp run(["token", "create", name | options]), do: create_token(name, options)

  defp run(["token", "list"]), do: ok(tokens())

  defp run(["token", "revoke", id]) do
    case Token.revoke(id) do
      :ok -> ok("Revoked #{id}.")
      {:error, :not_found} -> fail("No token has the id #{id}.")
    end
  end

  defp run(args), do: fail("tars: no command #{Enum.join(args, " ")}")

  # This node and every node connected to it that runs a daemon of its own.
  defp daemons do
    for daemon <- [node() | Node.list()],
        :erpc.call(daemon, Process, :whereis, [TarsDaemon.Agents]) != nil,
        do: daemon
  end

  defp create_token(name, options) do
    case token_options(options, %{}) do
      {:ok, %{scope: scope} = options} ->
        token(name, scope, Map.get(options, :can, Grant.actions()))

      _other ->
        fail("tars: token create NAME (--scope PREFIX | --all) [--can ACTIONS]")
    end
  end

  defp token_options([], options), do: {:ok, options}

  defp token_options(["--scope", scope | rest], options),
    do: token_options(rest, Map.put(options, :scope, scope))

  defp token_options(["--all" | rest], options),
    do: token_options(rest, Map.put(options, :scope, ""))

  defp token_options(["--can", can | rest], options),
    do: token_options(rest, Map.put(options, :can, String.split(can, ",", trim: true)))

  defp token_options(_other, _options), do: :error

  defp token(name, scope, can) do
    case Token.create(name, scope, can) do
      {:ok, secret, token} ->
        ok(
          Enum.join(
            [
              secret,
              "",
              "#{token.name} (#{token.id}) reaches #{reach(token.grant)}. " <>
                "This is the only time it is shown."
            ],
            "\n"
          )
        )

      {:error, message} when is_binary(message) ->
        fail(message)

      {:error, reason} ->
        fail("The token was not made: #{inspect(reason)}")
    end
  end

  defp tokens do
    rows =
      for token <- Token.list(),
          do: "  #{token.id}  #{token.name}  #{reach(token.grant)}  made #{token.created_at}"

    case rows do
      [] -> "No tokens. Make one with: tars token create NAME --scope PREFIX"
      [_row] -> Enum.join(["1 token:" | rows], "\n")
      rows -> Enum.join(["#{length(rows)} tokens:" | rows], "\n")
    end
  end

  defp reach(%Grant{scope: scope, can: can}) do
    agents = if scope == "", do: "every agent", else: "the agents under #{scope}"
    agents <> actions(can)
  end

  defp actions(can) do
    {names, [last]} = can |> Enum.map(&Atom.to_string/1) |> Enum.split(-1)

    cond do
      can == Grant.actions() -> ", for every action"
      names == [] -> ", to #{last}"
      true -> ", to #{Enum.join(names, ", ")} and #{last}"
    end
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
          do: "  #{key}  #{call.id}  #{Pattern.shown(call.name)}  #{prompt}" <> link(call)

    case rows do
      [] -> "Nothing is waiting on a person."
      rows -> Enum.join(["#{length(rows)} waiting:" | rows], "\n")
    end
  end

  # Where to authorize, for the operator reading this on the node; no notice
  # or event carries it.
  defp link(%{link: %{url: url, code: code}}) when is_binary(code),
    do: "\n      enter #{code} at #{url}"

  defp link(%{link: %{url: url}}), do: "\n      open #{url}"
  defp link(_call), do: ""

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
      {:error, :unrecorded} -> fail("#{key} could not record the decision, so it was not taken.")
    end
  end

  defp ok(text), do: IO.puts(text)

  defp fail(text) do
    IO.puts(text)
    exit({:shutdown, 1})
  end
end
