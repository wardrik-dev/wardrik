defmodule WardrikDaemon.CLI.Approvals do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Decide
  alias WardrikDaemon.CLI.Table

  @group "Approvals"

  @doc "Returns the commands on approvals."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "approval",
        group: @group,
        summary: "go through the calls agents wait on a person for, deciding each",
        details: [
          "At a terminal it shows each call and asks whether to approve it; Enter skips it.",
          "Elsewhere, or with --json, it lists them, as approval ls does."
        ],
        run: &reviewed/3
      },
      %Command{
        name: "approval ls",
        group: @group,
        summary: "the calls agents wait on a person for",
        details: [
          "A call held because its run read content from outside says so. A call in one of an",
          "agent's conversations shows the conversation; decide it with --conversation."
        ],
        run: &listed/3
      },
      %Command{
        name: "approval approve",
        group: @group,
        arguments: "AGENT CALL",
        switches: [note: :string, conversation: :string],
        count: 2,
        summary: "let a call run; a --note reaches the model beside its result",
        run: &decided(&1, &2, &3, "agent.approve", :note, "Approved")
      },
      %Command{
        name: "approval deny",
        group: @group,
        arguments: "AGENT CALL",
        switches: [reason: :string, conversation: :string],
        count: 2,
        summary: "refuse a call; a --reason reaches the model as its error",
        run: &decided(&1, &2, &3, "agent.deny", :reason, "Denied")
      }
    ]
  end

  @doc """
  After `command` at a terminal, says what waits on a person, if anything does: the command for
  one call, or `approval ls` for more. Approvals, `ask`, `follow` and set-up say it themselves.
  """
  @spec footer(Context.t(), Command.t()) :: :ok
  def footer(%{json?: false, terminal: %{tty?: true}} = cx, %Command{} = command) do
    with false <- quiet?(command),
         {:ok, %{"interrupts" => [_one | _more] = waiting}} <-
           Context.call(cx, "interrupts.list", %{}) do
      Context.puts(cx, ["\n", Owl.Data.tag(waits(cx, waiting), :light_black)])
    end

    :ok
  end

  def footer(_cx, _command), do: :ok

  defp quiet?(%Command{group: group, name: name}),
    do: group in [@group, "Set up"] or name in ["agent ask", "agent follow"]

  defp waits(cx, [%{"agent" => %{"id" => agent}, "interrupt" => interrupt} = waiting]) do
    name = typed(Context.names(cx), agent, waiting["conversation"])
    "1 call waits on you: #{cx.program} approval approve #{Decide.decision(name, interrupt)}"
  end

  defp waits(cx, waiting), do: "#{length(waiting)} calls wait on you: #{cx.program} approval"

  defp reviewed([], _flags, %{json?: false, terminal: %{input?: true}} = cx) do
    with {:ok, %{"interrupts" => waiting}} <- Context.call(cx, "interrupts.list", %{}) do
      review(cx, waiting)
    end
  end

  defp reviewed([], flags, cx), do: listed([], flags, cx)

  defp review(cx, []), do: Context.puts(cx, "Nothing waits on a person.")

  defp review(cx, waiting) do
    names = Context.names(cx)
    count = length(waiting)

    decided =
      waiting
      |> Enum.with_index(1)
      |> Enum.count(fn {waiting, at} -> reviewed?(cx, names, waiting, "#{at} of #{count}") end)

    Context.puts(cx, "Decided #{decided} of #{count}.")
  end

  defp reviewed?(cx, names, %{"agent" => %{"id" => agent}} = waiting, place) do
    conversation = waiting["conversation"]
    name = typed(names, agent, conversation)
    Context.puts(cx, ["\n", Owl.Data.tag("#{place} · #{name}", :light_black)])

    Decide.asked?(cx, waiting["interrupt"],
      log: Context.conversation(%{"agent" => agent}, %{conversation: conversation}),
      name: name,
      arguments: waiting["interrupt"]["arguments"]
    )
  end

  # How an agent, and its conversation, is typed in a command.
  defp typed(names, agent, conversation) do
    name = get_in(names, [agent, "shown"]) || agent
    if conversation, do: "#{name} --conversation #{conversation}", else: name
  end

  defp listed([], _flags, cx) do
    with {:ok, %{"interrupts" => listed} = answer} <- Context.call(cx, "interrupts.list", %{}) do
      names = if listed == [], do: %{}, else: Context.names(cx)

      Table.show(cx, answer,
        header: ["AGENT", "CONVERSATION", "CALL", "TOOL", "WHY"],
        rows:
          for(
            %{"agent" => %{"id" => agent}, "interrupt" => interrupt} = waiting <- listed,
            do: row(get_in(names, [agent, "shown"]) || agent, waiting["conversation"], interrupt)
          ),
        empty: "Nothing waits on a person."
      )
    end
  end

  defp row(agent, conversation, interrupt),
    do: [agent, conversation, interrupt["id"], interrupt["name"] || "the model", why(interrupt)]

  defp why(%{"labels" => [_label | _labels], "message" => message}),
    do: message <> " [after content from outside]"

  defp why(interrupt), do: interrupt["message"]

  defp decided([agent, call], flags, cx, operation, given, done) do
    with {:ok, id} <- Context.agent(cx, agent),
         decision = Context.conversation(%{"agent" => id, "interrupt" => call}, flags),
         input = Context.put(decision, Atom.to_string(given), flags[given]),
         {:ok, answer} <- Context.call(cx, operation, input),
         do: Context.done(cx, answer, "#{done} #{call}.")
  end
end
