defprotocol Wardrik.LLM.Client do
  @moduledoc """
  The seam every model call is made through: what reaches a provider, and
  what it answers, as Wardrik's own values.

  A host names the value once, as the `:llm` of its `Wardrik.Host`, and every
  model call of every agent, its turns, its history's summaries and its
  policy's judge alike, is made through it. `Wardrik.LLM.ReqLLM`, which
  reaches every provider ReqLLM does, is a host's client unless it names
  another.

      Wardrik.Host.new(store: store, llm: %MyApp.Gateway{url: url})

  A client is handed a `Wardrik.LLM.Request` the run's hooks and its
  `Wardrik.LLM.Dispatch` have already admitted, so it makes the call as the
  request says, with the key the request carries where it carries one, and
  answers what came of it: the model's `Wardrik.LLM.Answer`, or a
  `Wardrik.LLM.Error` saying why there is none, with the status the provider
  answered with, which `Wardrik.LLM.Retry.Backoff` reads to decide whether to
  ask again.

  The request's conversation holds the history and what is asked; its
  options hold the tools it offers, as `Wardrik.Tool`s, its system prompt as
  `:system_prompt`, and whatever the config's `:generation` set, which the
  client passes to its provider as it understands them.

  ## Streaming

  `stream/3` hands `emit` each piece of the answer as it arrives: text,
  reasoning, and the calls the model asks for, as they become known, so a
  turn can publish them. `emit` may throw to stop the call, as a turn
  interrupted does; the client lets the throw through and keeps nothing
  running after it.

  ## Models and prices

  `model/2` says what the client knows of a model, such as how many tokens
  it reads at once, and `price/3` what a call to it that used `usage` cost,
  in US dollars, or `nil` where the client cannot price it.
  """

  alias Wardrik.Conversation.ToolCall
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Model
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Usage

  @typedoc "A piece of an answer as it streams."
  @type delta() :: {:text, String.t()} | {:reasoning, String.t()} | {:tool_call, ToolCall.t()}

  @doc "Makes `request`, handing `emit` each piece of the answer as it arrives."
  @spec stream(t(), Request.t(), (delta() -> any())) :: {:ok, Answer.t()} | {:error, Error.t()}
  def stream(client, request, emit)

  @doc "Makes `request`, and answers once the whole answer is in."
  @spec generate(t(), Request.t()) :: {:ok, Answer.t()} | {:error, Error.t()}
  def generate(client, request)

  @doc """
  Asks an evaluation model `questions` about `state`, with the model and the
  options of `request`: each question a map, as `%{type: :boolean,
  instructions: "Is this urgent?"}`, under a name of the caller's. The
  answer's `object` holds each question's answer under its name.
  """
  @spec evaluate(t(), Request.t(), state: term(), questions: map()) ::
          {:ok, Answer.t()} | {:error, Error.t()}
  def evaluate(client, request, opts)

  @doc "What the client knows of the model `spec` names, or why it knows nothing."
  @spec model(t(), term()) :: {:ok, Model.t()} | {:error, term()}
  def model(client, spec)

  @doc "What a call to the model `spec` names that used `usage` cost, or `nil`."
  @spec price(t(), term(), Usage.t()) :: float() | nil
  def price(client, spec, usage)
end
