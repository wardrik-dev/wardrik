defmodule WardrikDaemon.CLI.Turns do
  @moduledoc """
  `wardrik cancel`: stopping what an agent is doing, and leaving the daemon
  and the agent running.

  `cancel KEY` stops the agent's turn at its next step and drops the
  messages waiting behind it, or abandons a turn waiting on a person, as
  `POST /v1/agents/{key}/cancel` does. A turn that stops within two seconds
  keeps what it said; one that does not is ended, and adds nothing. The agent
  answers its next message as usual, and a stopped turn stays stopped on
  whichever node holds the agent next.

  `cancel PREFIX/` does the same for every agent under a prefix, `acme/` or
  `acme/@jon/`, and `cancel --all` for every agent there is.
  """

  alias Wardrik.Agent
  alias Wardrik.Fleet
  alias WardrikDaemon.CLI.Command

  @doc "The commands that stop turns, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "cancel",
        arguments: "[PREFIX/ | KEY]",
        options: "[--all]",
        summary: "stop what an agent is doing, and leave it running",
        details: [
          "Its turn stops at its next step, the messages waiting behind it are dropped, and",
          "a turn waiting on a person is abandoned. PREFIX/ stops every agent under it, as",
          "acme/ or acme/@jon/, and --all every agent there is."
        ],
        switches: [all: :boolean],
        count: {0, 1},
        run: &cancel/2
      }
    ]
  end

  defp cancel(words, opts) do
    case {words, opts[:all] == true} do
      {[], true} -> {:ok, "Stopped #{agents(Fleet.kill(""))}."}
      {[target], false} -> target(target)
      _neither_or_both -> {:error, :usage}
    end
  end

  # The CLI has expanded it already, as Wardrik.Fleet.expand_prefix/1 does.
  defp target(target),
    do: if(String.ends_with?(target, "/"), do: under(target), else: one(target))

  defp under(prefix) do
    case Fleet.kill(prefix) do
      0 -> {:error, "No agent runs under #{prefix}."}
      count -> {:ok, "Stopped #{agents(count)} under #{prefix}."}
    end
  end

  defp one(key) do
    with %{state: _state} = status <- Agent.status(key),
         :ok <- Agent.interrupt(key) do
      {:ok, stopped(key, status)}
    else
      {:error, :not_found} -> {:error, "No agent runs under #{key}."}
    end
  end

  defp stopped(key, %{state: :idle, pending: 0}), do: "#{key} was doing nothing."
  defp stopped(key, %{state: :idle, pending: n}), do: "Dropped #{messages(n)} waiting for #{key}."

  defp stopped(key, %{state: :parked}),
    do: "Stopped #{key}, and abandoned the calls it waited on."

  defp stopped(key, %{pending: 0}), do: "Stopped #{key}."

  defp stopped(key, %{pending: n}),
    do: "Stopped #{key}, and dropped #{messages(n)} waiting behind it."

  defp agents(1), do: "1 agent"
  defp agents(count), do: "#{count} agents"

  defp messages(1), do: "1 message"
  defp messages(count), do: "#{count} messages"
end
