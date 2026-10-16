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

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Operations.ListParked
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
        group: "Decide",
        summary: "the calls agents are waiting on a person for",
        details: ["With --json, each call as an interrupt, with the agent it is for."],
        run: &parked/2,
        json: &interrupts/2
      },
      %Command{
        name: "approve",
        group: "Decide",
        arguments: "[KEY [CALL [NOTE]]]",
        summary: "run a parked call, with a note for the agent",
        count: {0, :any},
        run: &approve/2,
        live: &approve_chosen/3
      },
      %Command{
        name: "deny",
        group: "Decide",
        arguments: "[KEY [CALL [REASON]]]",
        summary: "refuse a parked call, saying why",
        count: {0, :any},
        run: &deny/2,
        live: &deny_chosen/3
      }
    ]
  end

  defp parked(words, opts) do
    with {:ok, %{"interrupts" => interrupts}} <- interrupts(words, opts) do
      rows =
        for %{"agent" => %{"id" => id}} = interrupt <- interrupts,
            key = AgentID.parse!(id),
            do: row_of(key, interrupt) <> read(interrupt) <> link(key, interrupt, opts[:session])

      case rows do
        [] -> {:ok, "Nothing is waiting on a person."}
        rows -> {:ok, Enum.join(["#{length(rows)} waiting:" | rows], "\n")}
      end
    end
  end

  defp interrupts(_words, opts) do
    with {:ok, parked} <- Wardrik.agents_parked(opts[:session], Prefix.all()),
         do: {:ok, ListParked.render(parked)}
  end

  defp row_of(key, %{"id" => id, "message" => prompt} = interrupt),
    do: "  #{key}  #{id}  #{Pattern.shown(interrupt["name"] || "model")}  #{prompt}"

  defp read(%{"labels" => [_ | _] = labels}),
    do: "\n      after reading #{Wardrik.Label.described(labels)}, which may be what asked for it"

  defp read(_interrupt), do: ""

  # Where to authorize, for the operator reading this on the node; no notice
  # or event carries it.
  defp link(key, %{"reason" => "authorization", "id" => id}, session) do
    case Wardrik.agent_authorization_read(session, key, id) do
      {:ok, %{url: url, code: code}} when is_binary(code) -> "\n      enter #{code} at #{url}"
      {:ok, %{url: url}} -> "\n      open #{url}"
      {:error, _gone} -> ""
    end
  end

  defp link(_key, _interrupt, _session), do: ""

  defp approve([key, call | note], opts),
    do: decided(key, [call], {:approve, Enum.join(note, " ")}, opts[:session])

  defp approve(_words, _opts), do: :live

  defp deny([key, call | reason], opts),
    do: decided(key, [call], {:deny, Enum.join(reason, " ")}, opts[:session])

  defp deny(_words, _opts), do: :live

  defp approve_chosen(words, opts, terminal),
    do: choose(words, terminal, :approve, opts[:session])

  defp deny_chosen(words, opts, terminal), do: choose(words, terminal, :deny, opts[:session])

  # Which calls, asked of the person at the terminal.
  defp choose(_words, %Terminal{input?: false}, verb, _by) do
    {:error,
     "wardrik #{verb} asks which call only where someone can answer; name it, as in " <>
       "wardrik #{verb} KEY CALL. wardrik parked lists them."}
  end

  defp choose(words, %Terminal{} = terminal, verb, session) do
    case {waiting(words, session), words} do
      {{:error, message}, _words} -> {:error, message}
      {[], []} -> {:ok, "Nothing is waiting on a person."}
      {[only], [_key]} -> decide([only], verb, terminal, session)
      {calls, _words} -> calls |> pick(verb, words == []) |> decide(verb, terminal, session)
    end
  end

  defp pick(calls, verb, every?) do
    Owl.IO.multiselect(calls,
      label: "Which to #{verb}? Their numbers, such as 1 3 or 1-3; Enter for none.",
      render_as: &(&1 |> row(every?) |> Ansi.chardata(false))
    )
  end

  defp row({key, interrupt}, every?) do
    [
      Pattern.shown(interrupt["name"] || "model"),
      if(every?, do: ["  ", to_string(key)], else: []),
      "  ",
      interrupt["message"]
    ]
  end

  defp decide([], _verb, _terminal, _session), do: {:ok, "Nothing was decided."}

  defp decide(chosen, :approve, _terminal, session),
    do: each_agent(chosen, {:approve, ""}, session)

  defp decide(chosen, :deny, terminal, session) do
    Terminal.puts(terminal, Owl.Data.tag("Why? Enter for no reason.", @faint))
    each_agent(chosen, {:deny, Owl.IO.input(optional: true) || ""}, session)
  end

  # One decision for each agent the chosen calls belong to.
  defp each_agent(chosen, decision, session) do
    answers =
      chosen
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)["id"])
      |> Enum.map(fn {key, ids} -> decided(key, ids, decision, session) end)

    lines = Enum.map_intersperse(answers, "\n", &said/1)
    if Enum.all?(answers, &match?({:ok, _}, &1)), do: {:ok, lines}, else: {:error, lines}
  end

  defp said({:ok, line}), do: line
  defp said({:error, %Error{message: message}}), do: message

  defp decided(key, ids, {verb, said}, session) do
    with {:ok, _decided} <- decision(verb, session, key, ids, said),
         do: {:ok, [done(verb), " ", names(ids), " for ", to_string(key), "."]}
  end

  # A note or a reason only where one was given.
  defp decision(:approve, session, key, ids, ""), do: Wardrik.agent_approve(session, key, ids)

  defp decision(:approve, session, key, ids, note),
    do: Wardrik.agent_approve(session, key, ids, note: note)

  defp decision(:deny, session, key, ids, ""), do: Wardrik.agent_deny(session, key, ids)

  defp decision(:deny, session, key, ids, reason),
    do: Wardrik.agent_deny(session, key, ids, reason: reason)

  defp done(:approve), do: "Approved"
  defp done(:deny), do: "Denied"

  defp names([only]), do: only
  defp names(ids), do: [Enum.intersperse(Enum.drop(ids, -1), ", "), " and ", List.last(ids)]

  # Every call a parked agent is waiting on, with the agent's ID, or those
  # of the one agent `words` name.
  defp waiting([], session), do: parked_under(Prefix.all(), session)

  defp waiting([key], session) do
    with {:ok, _snapshot} <- Wardrik.agent_read(session, key),
         [_ | _] = calls <-
           for({^key, _interrupt} = call <- parked_under(Prefix.of(key), session), do: call) do
      calls
    else
      [] -> {:error, "#{key} is not waiting on anything."}
      {:error, error} -> {:error, error}
    end
  end

  # The CLI's session may read every agent.
  defp parked_under(prefix, session) do
    {:ok, parked} = Wardrik.agents_parked(session, prefix)
    for {id, waiting} <- parked, do: {id, Value.interrupt(waiting)}
  end
end
