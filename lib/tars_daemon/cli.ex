defmodule TarsDaemon.CLI do
  @moduledoc """
  What `bin/tars` asks a running daemon. `main/1` runs one command on the
  daemon's node and prints its answer; a command that fails prints why and
  exits with status 1.

  | Command | Answer |
  | --- | --- |
  | `status` | the node, its agents, and each file that does not read |
  | `reload` | reads the agent and policy files again, then answers as `status` |
  | `ask KEY MESSAGE` | sends the agent a message, which it answers in a turn of its own |
  | `history KEY` | the agent's conversation, one message a paragraph |
  | `parked` | every call an agent is waiting on a person for |
  | `approve KEY CALL` | runs the call, and the agent carries on |
  | `deny KEY CALL [REASON]` | refuses the call, telling the agent why |
  """

  alias Tars.Agent
  alias Tars.Fleet
  alias TarsPolicy.Pattern

  @doc "Runs the command `args` names."
  @spec main([String.t()]) :: :ok
  def main(["status"]), do: ok(TarsDaemon.status())

  def main(["reload"]) do
    TarsDaemon.Agents.reload()
    ok(TarsDaemon.status())
  end

  def main(["ask", key | words]) when words != [] do
    case Agent.ask(key, Enum.join(words, " ")) do
      :ok -> ok("Asked #{key}.")
      {:error, :not_found} -> fail("No agent runs under #{key}.")
    end
  end

  def main(["history", key]) do
    case Agent.get_context(key) do
      {:error, :not_found} -> fail("No agent runs under #{key}.")
      context -> ok(history(context))
    end
  end

  def main(["parked"]), do: ok(parked())
  def main(["approve", key, call]), do: decide(key, call, :approve, "Approved")

  def main(["deny", key, call | reason]) do
    reason = if reason == [], do: "A person refused this call.", else: Enum.join(reason, " ")
    decide(key, call, {:deny, reason}, "Denied")
  end

  def main(args), do: fail("tars: no command #{Enum.join(args, " ")}")

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

  defp waiting(key) do
    case Agent.parked(key) do
      calls when is_list(calls) -> calls
      {:error, :not_found} -> []
    end
  end

  defp decide(key, call, decision, done) do
    case Agent.decide(key, %{call => decision}) do
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
