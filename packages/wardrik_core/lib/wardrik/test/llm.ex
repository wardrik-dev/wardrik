defmodule Wardrik.Test.LLM do
  @moduledoc """
  A `Wardrik.LLM.Client` that answers model calls from a script, in place of
  a provider.

  A client holds the process its script is kept in, its holder. The suite's
  client, `Wardrik.Test.llm/0`, is the one `Wardrik.Test.host/1` hands every
  agent, and its holder starts with `Wardrik.Test.children/0`; a test that
  runs agents sets its script, and runs alone, as the agents are the
  suite's:

      Wardrik.Test.LLM.stream(Wardrik.Test.llm(), [Wardrik.Test.LLM.final_answer("Hello.")])

  A test that builds its own run gives it a client of its own, whose holder
  runs under the test, so tests run at once without sharing a script:

      client = Wardrik.Test.LLM.start()
      Wardrik.Test.LLM.stream(client, [Wardrik.Test.LLM.tool_call("call_1", "ping", %{})])
      run = Wardrik.Test.run(host: Wardrik.Test.host(llm: client))

  A script answers each call with the next answer of a list (`stream/2`),
  by what each call asked (`answering/2`), or by its round (`by_round/2`).
  A call with no answer left, or made before any script is set, fails with
  a `Wardrik.LLM.Error` that says so.
  An answer is a `Wardrik.LLM.Answer`, as `final_answer/1`, `tool_call/3`
  and `evaluation/1` build them, a `Wardrik.LLM.Error` the call fails with,
  or a stream that breaks part way, as `broken/2` builds one. A streamed
  answer is handed out piece by piece first, its reasoning, its text and its
  tool calls, so the publishing path runs too.

  `:price`, given to `start/1` or set on the struct, is what a token read or
  written costs in US dollars; a client with none prices nothing. Every
  model is known, with the context window `:window` says, none by default,
  and no key.
  """

  use GenServer

  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.LLM.Answer

  @enforce_keys [:script]
  defstruct [:script, :price, :window]

  @type t() :: %__MODULE__{
          script: GenServer.server(),
          price: number() | nil,
          window: pos_integer() | nil
        }

  @typedoc "How a call is answered: an answer, the error it fails with, or a stream that breaks."
  @type answer() ::
          Answer.t() | Wardrik.LLM.Error.t() | {:broken, String.t(), Wardrik.LLM.Error.t()}

  @typedoc """
  What a call asked: its prompt, the last thing a person said, its system
  prompt, the names of the tools it offers, its model, every message it
  sent and the options it was made with; or, for an evaluation, its model,
  state and questions.
  """
  @type asked() :: %{
          optional(:prompt) => String.t(),
          optional(:messages) => [Wardrik.Conversation.message()],
          optional(:opts) => keyword(),
          optional(:system) => String.t() | nil,
          optional(:tools) => [String.t()],
          optional(:state) => term(),
          optional(:questions) => map(),
          model: term()
        }

  @doc "Starts a holder, under `name:` where given."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :none, Keyword.take(opts, [:name]))

  @doc """
  A client whose holder runs under the calling test, and stops with it.
  `:price` and `:window` are as above.
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    holder = ExUnit.Callbacks.start_supervised!(Supervisor.child_spec(__MODULE__, id: make_ref()))
    struct!(%__MODULE__{script: holder}, Keyword.take(opts, [:price, :window]))
  end

  @doc "Answers each call `client` makes with the next of `answers`, in order."
  @spec stream(t(), [answer()]) :: :ok
  def stream(%__MODULE__{} = client, answers) when is_list(answers),
    do: script(client, {:stream, answers})

  @doc """
  Answers each call `client` makes with what `fun` makes of what it asked,
  `t:asked/0`, in the process making the call. Nothing is shared between
  calls, so concurrent turns stay deterministic where an ordered list of
  answers would race.
  """
  @spec answering(t(), (asked() -> answer())) :: :ok
  def answering(%__MODULE__{} = client, fun) when is_function(fun, 1),
    do: script(client, {:answering, fun})

  @doc """
  Answers each call `client` makes with the answer at the index of the
  assistant messages its conversation already holds, the last where it holds
  more, every tool call in it given an id no earlier call was given, as a
  provider does.

  A turn replayed from a checkpoint asks nothing, so its calls keep the ids
  they had; a model asked again gets new ones, so a ledger keyed by call id
  cannot take the one for the other.
  """
  @spec by_round(t(), [answer()]) :: :ok
  def by_round(%__MODULE__{} = client, answers) when is_list(answers),
    do: script(client, {:by_round, answers})

  defp script(%__MODULE__{script: holder}, script), do: GenServer.call(holder, {:script, script})

  @doc "An answer the turn takes as final, saying `text`."
  @spec final_answer(String.t()) :: Answer.t()
  def final_answer(text), do: answer(Assistant.new(text), :stop)

  @doc "An answer asking for one call to the tool `name`, with `arguments`, under `id`."
  @spec tool_call(String.t(), String.t(), map()) :: Answer.t()
  def tool_call(id, name, arguments) do
    call = %ToolCall{id: id, name: name, arguments: arguments}
    answer(%Assistant{parts: [call]}, :tool_calls)
  end

  @doc """
  A stream that breaks once `text` has streamed, failing with `error`; a
  call that does not stream fails with `error` alone.
  """
  @spec broken(String.t(), Wardrik.LLM.Error.t()) :: answer()
  def broken(text, %Wardrik.LLM.Error{} = error) when is_binary(text), do: {:broken, text, error}

  @doc "An evaluation's answer, holding `object`, each question's answer under its name."
  @spec evaluation(map()) :: Answer.t()
  def evaluation(object) when is_map(object),
    do: %{answer(%Assistant{parts: []}, :stop) | object: object}

  @doc "An answer saying `message`, which stopped for `finish_reason`."
  @spec answer(Assistant.t(), Answer.finish_reason()) :: Answer.t()
  def answer(%Assistant{} = message, finish_reason),
    do: %Answer{message: message, finish_reason: finish_reason, model: "test", id: "resp_1"}

  @impl GenServer
  def init(:none), do: {:ok, :none}

  @impl GenServer
  def handle_call({:script, script}, _from, _script), do: {:reply, :ok, script}

  def handle_call(:take, _from, {:stream, [next | rest]}),
    do: {:reply, {:answer, next}, {:stream, rest}}

  def handle_call(:take, _from, script), do: {:reply, script, script}
end

defimpl Wardrik.LLM.Client, for: Wardrik.Test.LLM do
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Reasoning
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Model
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Usage

  def stream(client, request, emit) do
    case made(client, request, asked(request)) do
      %Answer{message: message} = answer ->
        Enum.each(message.parts, &streamed(&1, emit))
        {:ok, answer}

      %Error{} = error ->
        {:error, error}

      {:broken, text, error} ->
        emit.({:text, text})
        {:error, error}
    end
  end

  def generate(client, request), do: client |> made(request, asked(request)) |> said()

  def evaluate(client, request, opts) do
    asked = %{model: request.model_spec, state: opts[:state], questions: opts[:questions]}
    client |> made(request, asked) |> said()
  end

  def model(client, spec), do: {:ok, %Model{spec: spec, window: client.window}}

  def price(%{price: nil}, _spec, _usage), do: nil
  def price(%{price: usd}, _spec, %Usage{} = usage), do: usd * Usage.tokens(usage)

  defp made(client, request, asked) do
    case GenServer.call(client.script, :take) do
      {:answer, answer} -> answer
      {:answering, fun} -> fun.(asked)
      {:by_round, answers} -> answers |> Enum.at(rounds(request), List.last(answers)) |> fresh()
      script -> %Error{message: "the test model has no answer left in #{inspect(script)}"}
    end
  end

  defp said(%Answer{} = answer), do: {:ok, answer}
  defp said(%Error{} = error), do: {:error, error}
  defp said({:broken, _text, error}), do: {:error, error}

  defp asked(%Request{context: context, opts: opts, model_spec: spec}) do
    %{
      prompt: prompt(context),
      system: opts[:system_prompt],
      tools: opts |> Keyword.get(:tools, []) |> Enum.map(& &1.name),
      model: spec,
      messages: context.messages,
      opts: opts
    }
  end

  defp prompt(%Conversation{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %User{} = message -> Conversation.text(message)
      _message -> nil
    end)
  end

  defp rounds(%Request{context: context}),
    do: Enum.count(context.messages, &match?(%Assistant{}, &1))

  defp fresh(%Answer{message: message} = answer) do
    asked = System.unique_integer([:positive])

    parts =
      Enum.map(message.parts, fn
        %ToolCall{id: id} = call -> %{call | id: "#{id}_#{asked}"}
        part -> part
      end)

    %{answer | message: %{message | parts: parts}}
  end

  defp fresh(other), do: other

  defp streamed(%Reasoning{text: text}, emit), do: emit.({:reasoning, text})
  defp streamed(%Text{text: ""}, _emit), do: :ok
  defp streamed(%Text{text: text}, emit), do: emit.({:text, text})
  defp streamed(%ToolCall{} = call, emit), do: emit.({:tool_call, call})
  defp streamed(_part, _emit), do: :ok
end
