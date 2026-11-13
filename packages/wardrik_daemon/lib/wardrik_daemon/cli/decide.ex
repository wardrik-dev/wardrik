defmodule WardrikDaemon.CLI.Decide do
  @moduledoc false

  # A call an agent waits on a person for, shown as a card and decided where it's shown, or the
  # commands that decide it.

  alias WardrikDaemon.CLI.Context

  @doc """
  Shows `interrupt` and asks whether to approve it. Returns whether it was decided.

    * `:log` - the input naming its agent, and conversation if it's in one. Required.
    * `:name` - how its agent is typed, as `triage --conversation c1`. Required.
    * `:arguments` - its call's arguments, where they're known.
  """
  @spec asked?(Context.t(), map(), log: map(), name: String.t(), arguments: term()) :: boolean()
  def asked?(cx, interrupt, opts) do
    Context.puts(cx, ["\n", card(cx, interrupt, opts[:arguments])])

    case Owl.IO.input(
           label: "Approve #{called(interrupt)}? [y/n, Enter leaves it]",
           optional: true,
           cast: &answered/1
         ) do
      :leave -> false
      :approve -> decided?(cx, interrupt, "agent.approve", Keyword.fetch!(opts, :log), %{})
      :deny -> decided?(cx, interrupt, "agent.deny", Keyword.fetch!(opts, :log), reason())
    end
  end

  @doc "Writes the commands that decide each of `interrupts`, of the agent typed as `name`."
  @spec hint(Context.t(), [map()], String.t()) :: :ok
  def hint(cx, interrupts, name) do
    commands =
      for interrupt <- interrupts,
          verb <- ~w(approve deny),
          do: "  #{cx.program} approval #{verb} #{decision(name, interrupt)}"

    Context.puts(cx, Owl.Data.tag(Enum.join(["Decide with:" | commands], "\n"), :light_black))
  end

  @doc "Returns the arguments of `approval approve` and `approval deny` that name `interrupt`."
  @spec decision(String.t(), map()) :: String.t()
  def decision(name, interrupt) do
    case String.split(name, " ", parts: 2) do
      [agent, conversation] -> "#{agent} #{interrupt["id"]} #{conversation}"
      [agent] -> "#{agent} #{interrupt["id"]}"
    end
  end

  defp answered(nil), do: {:ok, :leave}

  defp answered(answer) do
    case String.downcase(answer) do
      yes when yes in ~w(y yes) -> {:ok, :approve}
      no when no in ~w(n no) -> {:ok, :deny}
      _other -> {:error, "y approves it, n denies it, and Enter leaves it waiting"}
    end
  end

  defp reason do
    case Owl.IO.input(label: "Why? The model reads it. Enter gives no reason.", optional: true) do
      nil -> %{}
      reason -> %{"reason" => reason}
    end
  end

  defp decided?(cx, interrupt, operation, log, given) do
    input =
      log
      |> Map.put("interrupt", interrupt["id"])
      |> Map.merge(given)

    case Context.call(cx, operation, input) do
      {:ok, _decided} ->
        true

      {:error, why} ->
        Context.puts(cx, Owl.Data.tag(why, :red))
        false
    end
  end

  defp called(%{"name" => name}), do: name
  defp called(_interrupt), do: "the model call"

  defp card(cx, interrupt, arguments) do
    arguments =
      case arguments do
        empty when empty in [nil, %{}] -> []
        arguments -> [Owl.Data.tag(pretty(arguments), :light_black)]
      end

    [why(interrupt, arguments), held(interrupt), arguments]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse("\n\n")
    |> Owl.Box.new(
      title: [" ", called(interrupt), " "],
      border_style: :solid_rounded,
      border_tag: :yellow,
      padding_x: 1,
      max_width: min(cx.terminal.width, 100),
      word_wrap: :normal
    )
  end

  # The prompt asks for a tool's approval, so the card says why only for another reason, or
  # where it has nothing else to show.
  defp why(%{"reason" => "tool_approval"}, [_shown | _arguments]), do: []
  defp why(interrupt, _arguments), do: interrupt["message"]

  defp held(%{"labels" => [_label | _labels]}),
    do: Owl.Data.tag("It follows content from outside.", :yellow)

  defp held(_interrupt), do: []

  defp pretty(arguments) do
    arguments
    |> :json.format()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end
end
