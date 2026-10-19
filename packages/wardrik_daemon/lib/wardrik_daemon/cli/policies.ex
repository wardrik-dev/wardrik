defmodule WardrikDaemon.CLI.Policies do
  @moduledoc """
  `wardrik policy`: a policy of `policies/` tried on what agents did, before
  it is trusted.

  `policy judge NAME` asks the policy's judge about the calls agents have
  made, as `WardrikDaemon.JudgeReplay` tries them, and sets what it decides
  beside how each call was decided when it was made. By default the calls
  are those of the agents whose definitions name the policy; `--agent` names
  an agent, with its conversations, or a prefix such as `acme/`, whatever
  policy they run under. `--last N` is how many, 20 by default.
  """

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.Config
  alias WardrikDaemon.JudgeReplay
  alias WardrikPolicy.Pattern

  @faint [:faint, :light_black]
  @last 20

  @doc "The policy commands, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "policy judge",
        group: "Decide",
        arguments: "NAME",
        options: "[--agent KEY|PREFIX/] [--last N]",
        summary: "try a policy's judge on the calls agents have made",
        details: [
          "Its model answers each question again, and what that decides is set beside how",
          "the call was decided; ! marks where they differ. The policy is read from its file",
          "as it is now, and nothing is decided or changed.",
          "The calls are those of the agents that run under the policy, or those under",
          "--agent, newest first, --last 20 by default. Only calls that ran are kept with",
          "their arguments, so a call refused, or waiting on a person, is not tried.",
          "With --json, each call with its answers, what they decide, and how it was decided."
        ],
        switches: [agent: :string, last: :integer],
        count: {1, 1},
        run: &judge/2,
        json: &judge_json/2
      }
    ]
  end

  defp judge([name], opts) do
    with {:ok, tried, where} <- tried(name, opts) do
      {:ok, shown(name, tried, where)}
    end
  end

  defp judge_json([name], opts) do
    with {:ok, tried, _where} <- tried(name, opts) do
      {:ok, %{"policy" => name, "calls" => Enum.map(tried, &document/1)}}
    end
  end

  defp tried(name, opts) do
    with {:ok, policy} <- JudgeReplay.policy(name),
         {:ok, prefixes, where} <- prefixes(store(opts), name, opts[:agent]),
         {:ok, last} <- last(Keyword.get(opts, :last, @last)) do
      {:ok, JudgeReplay.tried(opts[:as].host, policy.judge, under: prefixes, last: last), where}
    end
  end

  defp prefixes(store, name, nil) do
    case JudgeReplay.using(store, name) do
      [] ->
        {:error,
         "No agent runs under the policy #{name}; name some with --agent, as acme/books or acme/."}

      prefixes ->
        {:ok, prefixes, "the agents under #{name}"}
    end
  end

  defp prefixes(_store, _name, text) do
    with {:ok, prefix} <-
           Wardrik.AgentID.Prefix.expand(text, Config.org(WardrikDaemon.Host.config())),
         do: {:ok, [prefix], under(to_string(prefix))}
  end

  defp under(""), do: "every agent"
  defp under(prefix), do: prefix

  defp last(n) when n > 0, do: {:ok, n}
  defp last(_n), do: {:error, "--last is how many calls to try, 1 or more"}

  # -- shown -------------------------------------------------------------------

  defp shown(name, [], where) do
    "No call of #{where} that #{name}'s judge asks about is in the logs. Only calls that " <>
      "ran are kept with their arguments."
  end

  defp shown(name, tried, where) do
    differ = Enum.count(tried, &differs?/1)

    [
      "#{name}'s judge on #{count(tried)} of #{where}, newest first; ",
      "#{differ} decided otherwise than it would.\n",
      Enum.map(tried, &call/1),
      "\n",
      Owl.Data.tag(
        "Only calls that ran are tried. Its allow holds only where the run had read nothing " <>
          "from outside, which the log does not say.",
        @faint
      )
    ]
  end

  defp count([_only]), do: "1 call"
  defp count(tried), do: "#{length(tried)} calls"

  defp call(tried) do
    mark = if differs?(tried), do: Owl.Data.tag("! ", [:bright, :yellow]), else: "  "

    [
      "\n",
      mark,
      Owl.Data.tag(Pattern.shown(tried.tool), :bright),
      "  #{tried.agent}  #{at(tried.time)}\n",
      "    arguments  ",
      JSON.encode!(tried.arguments),
      "\n",
      answers(tried),
      "    judge      #{judged(tried.judged)}\n",
      "    decided    #{decided(tried.decided)}\n"
    ]
  end

  defp at(time) do
    {:ok, at, 0} = DateTime.from_iso8601(time)
    Calendar.strftime(at, "%Y-%m-%d %H:%M:%SZ")
  end

  defp answers(%{answers: {:ok, probabilities}, questions: questions}) do
    for {question, p} <- Enum.zip(questions, probabilities),
        do: "    #{:erlang.float_to_binary(p / 1, decimals: 2)}       #{question.question}\n"
  end

  defp answers(%{answers: {:error, reason}}), do: "    no answer  #{inspect(reason)}\n"

  defp judged({:deny, reason}), do: "refuses it: #{reason}"
  defp judged({:ask, prompt}), do: "asks a person: #{prompt}"
  defp judged({:allow, :judged}), do: "allows it"
  defp judged(:pass), do: "says nothing; the rules decide"

  defp decided(%{"resolved_by" => by}), do: "approved by #{person(by)}"
  defp decided(%{"by" => "person"}), do: "approved by a person"
  defp decided(%{"by" => "hook", "hooks" => hooks}), do: "allowed by #{Enum.join(hooks, ", ")}"
  defp decided(%{"by" => "default"}), do: "allowed, as no rule said otherwise"
  defp decided(%{"by" => "ledger"}), do: "answered from the ledger"

  defp person(%{"name" => name}), do: name
  defp person(%{"type" => type, "id" => id}), do: "#{type} #{id}"

  # Every call tried ran, so a judge that refuses or asks where no person
  # did, or allows where a person was asked, would have decided otherwise.
  defp differs?(%{judged: {:deny, _reason}}), do: true
  defp differs?(%{judged: {:ask, _prompt}, decided: decided}), do: decided["by"] != "person"
  defp differs?(%{judged: {:allow, :judged}, decided: decided}), do: decided["by"] == "person"
  defp differs?(%{judged: :pass}), do: false

  # -- --json ------------------------------------------------------------------

  defp document(tried) do
    %{
      "agent" => %{"id" => tried.agent},
      "tool_call" => %{"id" => tried.id, "name" => tried.tool, "arguments" => tried.arguments},
      "time" => tried.time,
      "answers" => answered(tried),
      "judged" => judged_document(tried.judged),
      "decided" => tried.decided,
      "differs" => differs?(tried)
    }
  end

  defp answered(%{answers: {:ok, probabilities}, questions: questions}) do
    for {question, p} <- Enum.zip(questions, probabilities),
        do: %{"question" => question.question, "probability" => p}
  end

  defp answered(%{answers: {:error, reason}, questions: questions}) do
    for question <- questions,
        do: %{"question" => question.question, "error" => inspect(reason)}
  end

  defp judged_document({effect, said}) when effect in [:deny, :ask],
    do: %{"decision" => Atom.to_string(effect), "message" => said}

  defp judged_document({:allow, :judged}), do: %{"decision" => "allow"}
  defp judged_document(:pass), do: %{"decision" => "none"}

  defp store(opts), do: Wardrik.Host.store(opts[:as].host)
end
