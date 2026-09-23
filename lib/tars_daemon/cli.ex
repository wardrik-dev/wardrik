defmodule TarsDaemon.CLI do
  @moduledoc """
  What `bin/tars` asks a running daemon. `main/1` runs one command on the
  daemon's node and prints its answer; a command that fails prints why and
  exits with status 1.

  | Command | Answer |
  | --- | --- |
  | `status` | the node, its agents, and each file that does not read |
  | `reload` | reads the agent and policy files again, then answers as `status` |
  | `parked` | every tool call an agent is waiting on a person for |
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

  def main(["parked"]), do: ok(parked())
  def main(["approve", key, call]), do: decide(key, call, :approve, "Approved")

  def main(["deny", key, call | reason]) do
    reason = if reason == [], do: "A person refused this call.", else: Enum.join(reason, " ")
    decide(key, call, {:deny, reason}, "Denied")
  end

  def main(args), do: fail("tars: no command #{Enum.join(args, " ")}")

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
