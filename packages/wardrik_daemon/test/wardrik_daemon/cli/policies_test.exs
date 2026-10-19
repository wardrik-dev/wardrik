defmodule WardrikDaemon.CLI.PoliciesTest do
  use ExUnit.Case, async: false
  use Mimic

  alias WardrikDaemon.Test.Host

  # Commands run over rpc build their callers on the daemon's host.
  setup do: Host.held()

  import ExUnit.CaptureIO

  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias WardrikDaemon.CLI

  @moduletag :tmp_dir

  @books "Does this call pay money out now?"

  @careful """
  ask: [web_search]
  judge:
    questions:
      - question: #{@books}
        tools: [books/*]
        deny: 0.9
        ask: 0.5
        allow: 0.05
  """

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join(dir, "policies/careful.yaml"), @careful)
    File.write!(Path.join(dir, "policies/plain.yaml"), "ask: [books/*]\n")
    Host.start_agents(dir)
    _files = WardrikDaemon.Agents.files(Host.agents(), host: Host.host())

    Host.declare(["test"])
    id = Wardrik.Test.Fleet.id("books")

    {:ok, _spec} = Host.define(id, %{"policy" => "careful"}, :defaults)

    on_exit(fn ->
      Wardrik.Definitions.delete(WardrikDaemon.Agents.definitions(Host.agents()), id)
    end)

    %{id: id}
  end

  defp command(args) do
    parent = self()

    output =
      capture_io(fn ->
        try do
          CLI.main(["--terminal=200,plain,no-input,user=ops" | Enum.map(args, &to_string/1)])
          send(parent, {:status, 0})
        catch
          :exit, {:shutdown, code} -> send(parent, {:status, code})
        end
      end)

    assert_receive {:status, status}
    {output, status}
  end

  # Writes a log for `id` of the calls `calls` made, each `{call_id, tool,
  # arguments, decided_by}`, and `{:approved, call_id, principal}` for one a
  # person approved.
  defp ran(%AgentID{} = id, calls) do
    source = Source.root(id, name: "turn")

    writer =
      Writer.open(
        Wardrik.Test.store(),
        Writer.new(id),
        Event.new(source, %Event.AgentStarted{node: node(), status: :idle, generation: "g1"})
      )

    Enum.reduce(calls, writer, fn
      {:approved, call_id, by}, writer ->
        appended(writer, source, %Event.CallDecided{call_id: call_id, decision: :approve, by: by})

      {call_id, tool, arguments, decided_by}, writer ->
        appended(writer, source, %Event.ToolStarted{
          call_id: call_id,
          name: tool,
          arguments: arguments,
          idempotency_key: nil,
          decided_by: decided_by
        })
    end)
  end

  defp appended(writer, source, payload) do
    {:ok, writer} = Writer.append(Wardrik.Test.store(), writer, Event.new(source, payload))
    writer
  end

  # Answers each call by the amount it names.
  defp answering do
    Wardrik.Test.LLM.answering(Wardrik.Test.llm(), fn %{state: %{"arguments" => arguments}} ->
      p = Map.get(arguments, "amount", 0) / 1000
      Wardrik.Test.LLM.evaluation(%{"q0" => %{"type" => "boolean", "probability" => p}})
    end)
  end

  test "policy judge tries its judge on the calls of the agents under the policy", %{id: id} do
    answering()

    ran(id, [
      {"c1", "books__list_invoices", %{"amount" => 10}, %{by: :hook, hooks: ["careful"]}},
      {"c2", "web_search", %{"q" => "rates"}, %{by: :default, hooks: []}},
      {"c3", "books__create_bill", %{"amount" => 700}, %{by: :default, hooks: []}},
      {:approved, "c4", Wardrik.Principal.new(:channel, "slack/U1", name: "maria")},
      {"c4", "books__send_payment", %{"amount" => 600}, %{by: :person, hooks: ["careful/judge"]}},
      {"c5", "books__send_payment", %{"amount" => 950}, %{by: :hook, hooks: ["careful"]}},
      {"c5", "books__send_payment", %{"amount" => 950}, %{by: :hook, hooks: ["careful"]}}
    ])

    {output, 0} = command(["policy", "judge", "careful"])

    assert output =~
             "careful's judge on 4 calls of the agents under careful, newest first; " <>
               "2 decided otherwise than it would."

    assert [_head, c5, c4, c3, c1, footer] = String.split(output, "\n\n")

    assert c5 =~ ~r/^! books\/send_payment  #{id}  \d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\n/
    assert c5 =~ ~s(arguments  {"amount":950})
    assert c5 =~ "0.95       #{@books}"
    assert c5 =~ "judge      refuses it: Judged 95% likely: #{@books}"
    assert c5 =~ "decided    allowed by careful"

    assert c4 =~ "  books/send_payment"
    assert c4 =~ "judge      asks a person"
    assert c4 =~ "decided    approved by maria"

    assert c3 =~ "! books/create_bill"
    assert c3 =~ "decided    allowed, as no rule said otherwise"

    assert c1 =~ "  books/list_invoices"
    assert c1 =~ "judge      allows it"
    assert footer =~ "Only calls that ran are tried."
    refute output =~ "web_search"
  end

  test "policy judge --agent tries an agent's conversations, or a prefix's agents", %{id: id} do
    answering()
    thread = AgentID.put_external_id(id, "C1-1696.1234")
    ran(thread, [{"c1", "books__create_bill", %{"amount" => 700}, %{by: :default, hooks: []}}])

    {output, 0} = command(["policy", "judge", "careful", "--agent", id, "--last", "5", "--json"])

    assert %{
             "policy" => "careful",
             "calls" => [
               %{
                 "agent" => %{"id" => agent},
                 "tool_call" => %{
                   "id" => "c1",
                   "name" => "books__create_bill",
                   "arguments" => %{"amount" => 700}
                 },
                 "answers" => [%{"question" => @books, "probability" => 0.7}],
                 "judged" => %{"decision" => "ask"},
                 "decided" => %{"by" => "default"},
                 "differs" => true
               }
             ]
           } = JSON.decode!(output)

    assert agent == to_string(thread)

    {output, 0} = command(["policy", "judge", "careful", "--agent", "#{id.org}/nobody"])
    assert output =~ "No call of #{id.org}/nobody that careful's judge asks about"
  end

  test "policy judge says why it cannot try a policy" do
    assert {"policies/ has no policy nope; it has careful, plain\n", 1} =
             command(["policy", "judge", "nope"])

    assert {output, 1} = command(["policy", "judge", "plain"])
    assert output =~ "The policy plain has no judge"

    assert {output, 1} = command(["policy", "judge", "careful", "--last", "0"])
    assert output =~ "--last is how many calls to try"
  end
end
