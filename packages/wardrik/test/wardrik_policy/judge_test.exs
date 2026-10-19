defmodule WardrikPolicy.JudgeTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Error
  alias Wardrik.Test.LLM
  alias Wardrik.Test.Tools.Deploy
  alias WardrikPolicy.Judge

  @books "Does this call change the company's books?"
  @money "Does this call send money outside the company?"

  defp judge(questions, rules \\ %{}) do
    WardrikPolicy.decode!(Map.put(rules, "judge", %{"questions" => questions}), "careful")
  end

  # A dispatch that tells the test what each model call it admits goes to.
  defmodule Admitting do
    defstruct [:test]
  end

  defimpl Wardrik.LLM.Dispatch, for: Admitting do
    def admit(admitting, request, _opts) do
      send(admitting.test, {:admitted, request.model_spec})
      {:ok, request}
    end

    def settle(_admitting, _request, _opts), do: :ok
  end

  setup do
    {:ok, llm: LLM.start()}
  end

  # Answers each question asked, by its text, with `probabilities`, and tells
  # the test what was asked.
  defp answering(llm, probabilities) do
    test = self()

    LLM.answering(llm, fn %{model: model, state: state, questions: questions} ->
      send(test, {:evaluated, model, state, questions})

      answers =
        Map.new(questions, fn {id, %{instructions: question}} ->
          {id, %{"type" => "boolean", "probability" => Map.fetch!(probabilities, question)}}
        end)

      LLM.evaluation(answers)
    end)
  end

  defp run(llm, policy, opts \\ []) do
    {labels, opts} = Keyword.pop(opts, :labels, [])

    run =
      [
        tools: [Deploy],
        id: Wardrik.AgentID.parse!("acme/books"),
        hooks: WardrikPolicy.hooks(policy),
        llm: llm
      ]
      |> Keyword.merge(opts)
      |> Wardrik.Test.run()

    %{run | labels: labels}
  end

  defp checked(llm, policy, opts \\ []),
    do: llm |> run(policy, opts) |> Wardrik.Test.check("deploy", %{"target" => "prod"})

  test "asks the questions naming a call together, with its tool and arguments", %{llm: llm} do
    answering(llm, %{@books => 0.9, @money => 0.1})

    policy =
      judge([
        %{"question" => @books, "tools" => ["deploy"], "ask" => 0.5},
        %{"question" => @money, "deny" => 0.8},
        %{"question" => "Is it about the weather?", "tools" => ["web_search"], "ask" => 0.5}
      ])

    assert %Wardrik.Call{state: :waiting, asks: [%{by: "careful/judge", prompt: prompt}]} =
             checked(llm, policy)

    assert prompt == "Judged 90% likely: #{@books}"

    assert_received {:evaluated, "typesafe:jev-latest", state, questions}
    assert state == %{"tool" => "deploy", "arguments" => %{"target" => "prod"}}

    assert questions |> Map.values() |> Enum.map(& &1.instructions) |> Enum.sort() ==
             Enum.sort([@books, @money])
  end

  test "decides by the strictest answer, deny over ask over allow" do
    deny = %{question: @money, tools: [], deny: 0.8, ask: nil, allow: nil, message: nil}
    ask = %{question: @books, tools: [], deny: nil, ask: 0.5, allow: 0.05, message: "Books!"}

    assert Judge.judged([deny, ask], {:ok, [0.9, 0.9]}) == {:deny, "Judged 90% likely: #{@money}"}
    assert Judge.judged([deny, ask], {:ok, [0.1, 0.6]}) == {:ask, "Books!"}
    assert Judge.judged([deny, ask], {:ok, [0.1, 0.01]}) == {:allow, :judged}
    assert Judge.judged([deny, ask], {:ok, [0.1, 0.2]}) == :pass
    assert Judge.judged([deny], {:ok, [0.01]}) == :pass
  end

  test "allows a call by name where every question allowing it is below its threshold", %{
    llm: llm
  } do
    answering(llm, %{@books => 0.01, @money => 0.02})

    policy =
      judge([
        %{"question" => @books, "allow" => 0.05},
        %{"question" => @money, "allow" => 0.05, "deny" => 0.8}
      ])

    assert %Wardrik.Call{state: :allowed, allowed: ["careful/judge"]} = checked(llm, policy)

    answering(llm, %{@books => 0.01, @money => 0.3})
    assert %Wardrik.Call{state: :waiting} = checked(llm, policy)
  end

  test "allows nothing once the run has read from outside", %{llm: llm} do
    answering(llm, %{@books => 0.01})
    policy = judge([%{"question" => @books, "allow" => 0.05}])

    assert %Wardrik.Call{state: :waiting} = checked(llm, policy, labels: ["outside"])
  end

  test "never lifts a call a rule asks about or denies", %{llm: llm} do
    answering(llm, %{@books => 0.01})
    question = %{"question" => @books, "allow" => 0.05}

    assert %Wardrik.Call{state: :waiting, asks: [%{by: "careful"}]} =
             checked(llm, judge([question], %{"ask" => ["deploy"]}))

    assert %Wardrik.Call{state: :denied, denied: %{by: "careful"}} =
             checked(llm, judge([question], %{"deny" => ["deploy"]}))
  end

  test "asks a person where it cannot answer and could have asked or denied", %{llm: llm} do
    policy = judge([%{"question" => @books, "ask" => 0.5}])
    LLM.stream(llm, [%Error{message: "the model timed out"}, LLM.evaluation(%{})])

    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt}]} = checked(llm, policy)
    assert prompt =~ "The judge could not answer (the model timed out)"

    assert Judge.judged([%{deny: nil, ask: nil, allow: 0.05}], {:error, :timeout}) == :pass

    assert Judge.evaluate(run(llm, policy), policy.judge, %{name: "deploy", arguments: %{}}) ==
             {:error, :no_answer}
  end

  test "makes its model call as the run's, which its dispatch admits and its hooks decide", %{
    llm: llm
  } do
    answering(llm, %{@books => 0.9})
    policy = judge([%{"question" => @books, "ask" => 0.5}])
    host = Wardrik.Test.host(llm: llm, dispatch: %__MODULE__.Admitting{test: self()})

    assert %Wardrik.Call{state: :waiting} = checked(llm, policy, host: host)
    assert_received {:admitted, "typesafe:jev-latest"}

    spent = WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1, "on_exhausted" => "deny"}})
    agent = Wardrik.Test.Fleet.id("judged")
    run = run(llm, policy, id: agent, hooks: WardrikPolicy.hooks(spent))

    on_exit(fn ->
      for key <- WardrikStore.keys(Wardrik.Test.store(), :budgets, to_string(agent)),
          do: WardrikStore.delete(Wardrik.Test.store(), :budgets, key)
    end)

    :ok =
      WardrikPolicy.Meter.spend(
        WardrikPolicy.Spend.key(
          run.source.agent_id,
          "policy/budget",
          WardrikPolicy.Budget.window(spent.budget, "", DateTime.utc_now())
        ),
        0,
        10
      )

    assert {:error, {:policy_denied, _reason}} =
             Judge.evaluate(run, policy.judge, %{name: "deploy", arguments: %{}})
  end

  test "judges no call its questions do not name, and no model call", %{llm: llm} do
    policy = judge([%{"question" => @books, "tools" => ["books/*"], "ask" => 0.5}])

    assert %Wardrik.Call{state: :waiting, asks: asks} = checked(llm, policy)
    refute Enum.any?(asks, &(&1.by == "careful/judge"))
    assert Judge.call(%Wardrik.Call{id: "m", target: :model}, policy.judge) == :pass
    assert Judge.asked(policy.judge, "deploy") == []
    assert [%{question: @books}] = Judge.asked(policy.judge, "books__create_bill")
  end

  describe "written down" do
    test "reads back as it was written" do
      fields = %{
        "model" => "typesafe:jev-latest",
        "questions" => [
          %{"question" => @books, "tools" => ["books/*"], "ask" => 0.5, "allow" => 0.05},
          %{"question" => @money, "deny" => 0.8, "message" => "No money leaves."}
        ]
      }

      policy = WardrikPolicy.decode!(%{"judge" => fields})
      assert WardrikPolicy.encode(policy)["judge"] == fields
      assert [%{name: "policy"}, %{name: "policy/judge"}] = WardrikPolicy.hooks(policy)
    end

    test "says what does not read, and where" do
      for {judge, said} <- [
            {%{"questions" => []}, "judge.questions is a list of questions"},
            {%{"questions" => [%{"ask" => 0.5}]}, "judge.questions[1].question is the question"},
            {%{"questions" => [%{"question" => "Q?"}]}, "judge.questions[1] decides nothing"},
            {%{"questions" => [%{"question" => "Q?", "ask" => 1.5}]},
             "judge.questions[1].ask is a probability between 0 and 1"},
            {%{"questions" => [%{"question" => "Q?", "ask" => 0.2, "allow" => 0.5}]},
             "judge.questions[1] has allow at or below ask"},
            {%{
               "questions" => [%{"question" => "Q?", "ask" => 0.5, "tools" => ["write_file(x)"]}]
             }, "judge.questions[1].tools names tools alone"},
            {%{
               "questions" => [
                 %{"question" => "Q?", "ask" => 0.5, "tools" => ["books/pay(amount > 5)"]}
               ]
             }, "judge.questions[1].tools names tools alone"},
            {%{"questions" => [%{"question" => "Q?", "ask" => 0.5, "when" => "x"}]},
             "judge.questions[1].when is not a setting"},
            {%{"model" => "", "questions" => [%{"question" => "Q?", "ask" => 0.5}]},
             "judge.model is a model"},
            {"yes", "judge is a model and its questions"}
          ] do
        assert {:error, message} = WardrikPolicy.decode(%{"judge" => judge})
        assert message =~ said
      end
    end
  end
end
