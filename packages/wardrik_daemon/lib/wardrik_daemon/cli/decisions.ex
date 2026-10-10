defmodule WardrikDaemon.CLI.Decisions do
  @moduledoc """
  `wardrik parked`, `approve` and `deny`: the calls agents are waiting on a
  person for, and deciding them.

  `approve KEY CALL [NOTE]` and `deny KEY CALL [REASON]` decide one call:
  the model reads the note beside the call's answer, and the reason in place
  of it. A note never changes the call, which runs as the model wrote it. Without
  the call they run live and ask: `approve KEY` approves the one call `KEY`
  waits on, and asks which where it waits on several, and `approve` alone
  asks among every call waiting. `deny` asks why as well. Where nobody can
  type an answer, as from a script, they say to name the call instead.

  `bin/wardrik` reaches the node with its cookie, which only the account the
  node runs as can read, so that account is who decides.
  """

  alias Wardrik.Agent
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet
  alias WardrikConsole.Ansi
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal
  alias WardrikPolicy.Pattern

  @faint [:faint, :light_black]

  @doc "The commands that decide, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "parked",
        summary: "the calls agents are waiting on a person for",
        details: ["With --json, each call as an interrupt, with the agent it is for."],
        run: &parked/2,
        json: &interrupts/2
      },
      %Command{
        name: "approve",
        arguments: "[KEY [CALL [NOTE]]]",
        summary: "run a parked call, with a note for the agent",
        count: {0, :any},
        run: &approve/2,
        live: &approve_chosen/3
      },
      %Command{
        name: "deny",
        arguments: "[KEY [CALL [REASON]]]",
        summary: "refuse a parked call, saying why",
        count: {0, :any},
        run: &deny/2,
        live: &deny_chosen/3
      }
    ]
  end

  defp parked(_words, _opts) do
    rows =
      for {key, call, prompt} <- waiting(),
          do:
            "  #{key}  #{call.id}  #{Pattern.shown(call.name)}  #{prompt}" <>
              read(call) <> link(call)

    case rows do
      [] -> {:ok, "Nothing is waiting on a person."}
      rows -> {:ok, Enum.join(["#{length(rows)} waiting:" | rows], "\n")}
    end
  end

  defp interrupts(_words, _opts) do
    interrupts =
      for {key, call, prompt} <- waiting(),
          do: Map.put(Value.interrupt({call, prompt}), "agent", %{"id" => to_string(key)})

    {:ok, %{"interrupts" => interrupts}}
  end

  defp read(%{labels: [_ | _] = labels}),
    do: "\n      after reading #{Wardrik.Label.described(labels)}, which may be what asked for it"

  defp read(_call), do: ""

  # Where to authorize, for the operator reading this on the node; no notice
  # or event carries it.
  defp link(%{link: %{url: url, code: code}}) when is_binary(code),
    do: "\n      enter #{code} at #{url}"

  defp link(%{link: %{url: url}}), do: "\n      open #{url}"
  defp link(_call), do: ""

  defp approve([key, call], opts), do: decided(key, [call], :approve, opts[:by])

  defp approve([key, call | note], opts),
    do: decided(key, [call], {:approve, Enum.join(note, " ")}, opts[:by])

  defp approve(_words, _opts), do: :live

  defp deny([key, call | reason], opts),
    do: decided(key, [call], {:deny, reason(reason)}, opts[:by])

  defp deny(_words, _opts), do: :live

  defp reason([]), do: "A person refused this call."
  defp reason(words), do: Enum.join(words, " ")

  defp approve_chosen(words, opts, terminal), do: choose(words, terminal, :approve, opts[:by])
  defp deny_chosen(words, opts, terminal), do: choose(words, terminal, :deny, opts[:by])

  # Which calls, asked of the person at the terminal.
  defp choose(_words, %Terminal{input?: false}, verb, _by) do
    {:error,
     "wardrik #{verb} asks which call only where someone can answer; name it, as in " <>
       "wardrik #{verb} KEY CALL. wardrik parked lists them."}
  end

  defp choose(words, %Terminal{} = terminal, verb, by) do
    case {waiting(words), words} do
      {{:error, message}, _words} -> {:error, message}
      {[], []} -> {:ok, "Nothing is waiting on a person."}
      {[only], [_key]} -> decide([only], verb, terminal, by)
      {calls, _words} -> calls |> pick(verb, words == []) |> decide(verb, terminal, by)
    end
  end

  defp pick(calls, verb, every?) do
    Owl.IO.multiselect(calls,
      label: "Which to #{verb}? Their numbers, such as 1 3 or 1-3; Enter for none.",
      render_as: &(&1 |> row(every?) |> Ansi.chardata(false))
    )
  end

  defp row({key, call, prompt}, every?) do
    [Pattern.shown(call.name), if(every?, do: ["  ", to_string(key)], else: []), "  ", prompt]
  end

  defp decide([], _verb, _terminal, _by), do: {:ok, "Nothing was decided."}

  defp decide(chosen, :approve, _terminal, by), do: each_agent(chosen, :approve, by)

  defp decide(chosen, :deny, terminal, by) do
    Terminal.puts(terminal, Owl.Data.tag("Why? Enter for no reason.", @faint))
    each_agent(chosen, {:deny, reason(List.wrap(Owl.IO.input(optional: true)))}, by)
  end

  # One decision for each agent the chosen calls belong to.
  defp each_agent(chosen, decision, by) do
    answers =
      chosen
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1).id)
      |> Enum.map(fn {key, ids} -> decided(key, ids, decision, by) end)

    lines = Enum.map_intersperse(answers, "\n", &elem(&1, 1))
    if Enum.all?(answers, &match?({:ok, _}, &1)), do: {:ok, lines}, else: {:error, lines}
  end

  defp decided(key, ids, decision, by) do
    case Agent.decide(key, Map.new(ids, &{&1, decision}), by: by) do
      :ok ->
        {:ok, [done(decision), " ", names(ids), " for ", to_string(key), "."]}

      {:error, :not_found} ->
        {:error, "No agent runs under #{key}."}

      {:error, :not_parked} ->
        {:error, "#{key} is not waiting on anything."}

      {:error, :stale_decision} ->
        {:error, [to_string(key), " is not waiting on ", names(ids), "."]}

      {:error, :unrecorded} ->
        {:error, "#{key} could not record the decision, so it was not taken."}
    end
  end

  defp done(:approve), do: "Approved"
  defp done({:approve, _note}), do: "Approved"
  defp done({:deny, _reason}), do: "Denied"

  defp names([only]), do: only
  defp names(ids), do: [Enum.intersperse(Enum.drop(ids, -1), ", "), " and ", List.last(ids)]

  # Every call a parked agent is waiting on, with the agent's key, or those
  # of the one agent `words` name.
  defp waiting,
    do: for({key, calls} <- parked_agents(), {call, prompt} <- calls, do: {key, call, prompt})

  defp waiting([]), do: waiting()

  defp waiting([key]) do
    case Agent.parked(key) do
      {:error, :not_found} -> {:error, "No agent runs under #{key}."}
      [] -> {:error, "#{key} is not waiting on anything."}
      calls -> for {call, prompt} <- calls, do: {key, call, prompt}
    end
  end

  defp parked_agents do
    for %{status: :parked, id: key} <- Fleet.list(),
        calls = Agent.parked(key),
        is_list(calls),
        do: {key, calls}
  end
end
