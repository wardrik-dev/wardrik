defmodule WardrikTesting.Server do
  @moduledoc """
  A `Wardrik.Server` that answers from a script, for testing packages without Wardrik.

      setup do
        :ok = WardrikTesting.Server.start(:my_test)
        scope = Wardrik.Scope.new(WardrikTesting.Server, wardrik: :my_test, principal: "acme/@maria")
        %{scope: scope}
      end

  ## Messages

  The calling test is sent:

    * `{:ran, id, input}` for each operation.
    * `{:streamed, id, input}` for each stream.
    * `{:asked, conversation, text, principal_id}` for each message.
    * `{:offered, worker, tools}` for each worker's tools.

  ## Answers

    * Each operation and stream is first put to `:authorize`. A refusal answers `:forbidden` or
      `:not_found`.
    * An operation returns the protocol's example output, or `nil` if it has none.
    * `acme/missing`, and any conversation under it, isn't found.
    * The agents given as `:offered` are listed and defined with their channels.
    * `agent.read` reports whether the conversation is waiting on a person, as its last turn left it.
    * A message is answered as `WardrikTesting.Script` describes. The events are written to the
      conversation's log if the test started `events/1`.
    * A stream with `"after" => "nope"` fails with `:invalid_request`.
    * Following `acme/broken` fails partway. Following `acme/waiting` waits on `call_1`. Following
      any other agent replies `"Re: "` followed by the input.
  """

  @behaviour Wardrik.Server

  alias Wardrik.Error
  alias Wardrik.Scope
  alias Wardrik.Server.Request
  alias WardrikTesting.Script

  @event %{
    "specversion" => "1.0",
    "id" => "1",
    "source" => "wardrik://test/agents/acme/triage",
    "type" => "wardrik.run.completed",
    "time" => "2026-10-28T12:00:00Z",
    "data" => %{"run" => %{"id" => "r1"}, "messages" => []}
  }

  @doc """
  Starts the server for the calling test under `name`.

  Registers the test process as `name`, and stops the server when the test ends.

  ## Options

    * `:authorize` - decides each `Wardrik.Server.Request`, returning `:ok`, or
      `{:error, :forbidden | :not_found}`. Allows everything unless set.
    * `:offered` - agents it offers, each as `{id, channels}` or `{id, channels, description}`.
      `[]` unless set.
  """
  @spec start(atom(), keyword()) :: :ok
  def start(name, opts \\ []) do
    opts = Keyword.validate!(opts, authorize: &allow/1, offered: [])
    state = state_name(name)
    initial = fn -> %{authorize: opts[:authorize], offered: opts[:offered], held: %{}} end

    ExUnit.Callbacks.start_supervised!(%{
      id: state,
      start: {Agent, :start_link, [initial, [name: state]]}
    })

    Process.register(self(), name)
    :ok
  end

  @doc "Returns the name to start `WardrikEvents` under, so turns are written to it."
  @spec events(atom()) :: atom()
  def events(name), do: Module.concat(name, Events)

  @doc """
  Adds the agent `:id` to those offered, answering in `:channels`, with any `:description`.

      :ok = WardrikTesting.Server.add_agent(:my_test, id: "acme/books", channels: ["chat"])
  """
  @spec add_agent(atom(), keyword()) :: :ok
  def add_agent(name, agent) do
    offered = {Keyword.fetch!(agent, :id), Keyword.fetch!(agent, :channels), agent[:description]}
    update(name, &%{&1 | offered: &1.offered ++ [offered]})
  end

  @doc "Replaces the agents offered with `offered`, each as `{id, channels}`."
  @spec offer_agents(atom(), [{String.t(), [String.t()]}]) :: :ok
  def offer_agents(name, offered), do: update(name, &%{&1 | offered: offered})

  @doc false
  @spec hold(atom(), String.t(), {String.t(), [map()]}) :: :ok
  def hold(name, conversation, held),
    do: update(name, &%{&1 | held: Map.put(&1.held, conversation, held)})

  @doc false
  @spec tell(atom(), term()) :: :ok
  def tell(name, message) do
    with pid when is_pid(pid) <- Process.whereis(name), do: send(pid, message)
    :ok
  end

  @impl Wardrik.Server
  def run(%Request{scope: %Scope{wardrik: name} = scope, operation: id, input: input} = request) do
    tell(name, {:ran, id, input})

    with :ok <- authorized(request), do: answer(scope, id, input)
  end

  @impl Wardrik.Server
  def stream(%Request{scope: %Scope{wardrik: name}, operation: id, input: input} = request) do
    tell(name, {:streamed, id, input})

    with :ok <- authorized(request), do: streamed(input)
  end

  defp streamed(%{"after" => "nope"}),
    do: {:error, Error.new(:invalid_request, "That cursor doesn't read.")}

  defp streamed(_input),
    do: {:ok, Stream.concat([{@event, "cursor-1"}], Stream.repeatedly(&quiet/0))}

  defp authorized(%Request{scope: %Scope{wardrik: name}} = request) do
    case state(name).authorize.(request) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, Error.new(:forbidden, "You may not do that.")}
      {:error, :not_found} -> {:error, Error.new(:not_found, "There's nothing here.")}
    end
  end

  defp allow(_request), do: :ok

  @impl Wardrik.Server
  def follow(%{agent: "acme/broken"}, _opts), do: [{:text, "Half"}, {:failed, :boom}]

  def follow(%{agent: "acme/waiting"}, _opts),
    do: [{:waiting, [%Wardrik.Interrupt{id: "call_1", reason: :tool_approval}]}]

  def follow(%{input: input}, _opts),
    do: [
      {:text, "Re: "},
      {:text, input},
      {:done, %Wardrik.Reply{message: "m1", run: "r1", text: "Re: " <> input}}
    ]

  @impl Wardrik.Server
  def offer(%Scope{wardrik: name}, tools) do
    tell(name, {:offered, self(), tools})
    :ok
  end

  @impl Wardrik.Server
  def answer({caller, ref}, message) do
    send(caller, {ref, message})
    :ok
  end

  defp answer(_scope, _id, %{"agent" => "acme/missing" <> _rest = agent}),
    do: {:error, Error.new(:not_found, "There's no agent #{agent}.")}

  defp answer(%Scope{wardrik: name}, "agents.list", _input) do
    agents =
      for offered <- state(name).offered,
          id = elem(offered, 0),
          do: %{"id" => id, "name" => Path.basename(id)}

    {:ok, %{"agents" => agents}}
  end

  defp answer(%Scope{wardrik: name}, "agent.definition", %{"agent" => agent}),
    do: name |> state() |> Map.fetch!(:offered) |> List.keyfind(agent, 0) |> defined(agent)

  defp answer(%Scope{wardrik: name}, "agent.read", %{"agent" => conversation}) do
    {status, interrupts} = Map.get(state(name).held, conversation, {"idle", []})
    agent = %{"id" => conversation, "name" => Path.basename(conversation)}
    {:ok, %{"agent" => agent, "status" => status, "pending" => 0, "interrupts" => interrupts}}
  end

  defp answer(scope, "agent.ask", input), do: Script.ask(scope, input)

  defp answer(scope, id, input) when id in ["agent.approve", "agent.deny"],
    do: Script.decide(scope, id, input)

  defp answer(scope, "agent.cancel", input), do: Script.cancel(scope, input)

  defp answer(_scope, id, _input) do
    case WardrikProtocol.operation(id).output do
      %{"examples" => [example | _rest]} -> {:ok, example}
      _none -> {:ok, nil}
    end
  end

  defp defined({agent, channels}, agent), do: defined({agent, channels, nil}, agent)

  defp defined({agent, channels, description}, agent) do
    described = description || "Answers #{agent}."
    definition = %{"model" => "m", "channels" => channels, "description" => described}
    {:ok, %{"definition" => definition, "missing" => []}}
  end

  defp defined(nil, agent), do: {:error, Error.new(:not_found, "There's no agent #{agent}.")}

  defp quiet do
    receive do
      :never -> :never
    end
  end

  defp state(name), do: Agent.get(state_name(name), & &1)
  defp update(name, change), do: Agent.update(state_name(name), change)
  defp state_name(name), do: Module.concat(name, WardrikTesting)
end
