defmodule WardrikPolicy.Judge do
  @moduledoc """
  Calls a policy has judged by a model: questions about a call, each
  answered yes or no with a probability, and what each answer decides.

      judge:
        model: typesafe:jev-latest
        questions:
          - question: Does this call record, change or delete anything in the company's books?
            tools: [books/*]
            ask: 0.5
            allow: 0.05
          - question: Does this call send money to a person or an account outside the company?
            ask: 0.5
            deny: 0.9

  For each tool call, the questions whose `tools` name it, every tool's
  where they name none, are asked together in one request to `model`, an
  evaluation model `ReqLLM.evaluate/4` reaches, with the tool's name and its
  arguments as the state. A question decides by its probability of yes:

    * at or above `deny`, the call is refused
    * else at or above `ask`, a person is asked first
    * below `allow`, the call is allowed by name, as an `allow` rule allows
      one, where the run has read nothing from outside (no `"outside"`
      label), and where every question with an `allow` that was asked is
      below its own
    * otherwise the judge says nothing, and the rules decide alone

  A deny over an ask over an allow, across the questions, and across the
  policy's other hooks: a judge's allow never lifts a call a rule asks
  about or denies. `message` is what a person is asked, or what the model
  is told it may not do, in place of the question and its probability.

  A judge that cannot answer, because the model cannot be reached or says
  nothing usable, asks a person where a question it asked could ask or
  deny, and otherwise says nothing.

  ## Caution

  A call's arguments may have been written by what the run read, so they may
  be written to fool the judge: a judge's allow holds only for a run that
  has read nothing from outside, and a judge is a second opinion beside the
  rules, not in place of them. Its probabilities are calibrated by its model
  in general, not on this deployment's calls, so its thresholds are to be
  tried on calls like the agent's before they are trusted.
  """

  @enforce_keys [:questions]
  defstruct model: "typesafe:jev-latest", questions: []

  alias Wardrik.Call
  alias WardrikPolicy.Pattern

  @type question() :: %{
          question: String.t(),
          tools: [Pattern.t()],
          deny: float() | nil,
          ask: float() | nil,
          allow: float() | nil,
          message: String.t() | nil
        }

  @type t() :: %__MODULE__{model: String.t(), questions: [question()]}

  @keys ~w(model questions)
  @question_keys ~w(question tools deny ask allow message)
  @effects [:deny, :ask, :allow]
  @outside "outside"

  @behaviour Wardrik.Hook

  @impl Wardrik.Hook
  def init(%__MODULE__{} = judge), do: judge

  @impl Wardrik.Hook
  def call(%Call{target: %Call.Tool{name: name, arguments: arguments}, run: run}, judge) do
    case asked(judge, name) do
      [] -> :pass
      asked -> asked |> judged(evaluate(judge.model, name, arguments, asked)) |> held(run)
    end
  end

  def call(%Call{}, %__MODULE__{}), do: :pass

  @doc "The questions `judge` asks about a call to the tool `name`, in their order."
  @spec asked(t(), String.t()) :: [question()]
  def asked(%__MODULE__{questions: questions}, name),
    do: Enum.filter(questions, &names?(&1, name))

  defp names?(%{tools: []}, _name), do: true
  defp names?(%{tools: tools}, name), do: Enum.any?(tools, &Pattern.match?(&1, name))

  @doc """
  What the model answers for a call to `name` with `arguments`: each
  question's probability of yes, in their order, or why there is none.
  """
  @spec evaluate(String.t(), String.t(), map(), [question()]) ::
          {:ok, [float()]} | {:error, term()}
  def evaluate(model, name, arguments, asked) do
    questions =
      asked
      |> Enum.with_index()
      |> Map.new(fn {asked, n} -> {"q#{n}", %{type: :boolean, instructions: asked.question}} end)

    state = %{"tool" => Pattern.shown(name), "arguments" => arguments}

    with {:ok, %{object: answers}} <- ReqLLM.evaluate(model, state, questions) do
      probabilities(answers, length(asked))
    end
  end

  defp probabilities(answers, count) do
    probabilities = for n <- 0..(count - 1), do: get_in(answers, ["q#{n}", "probability"])

    if Enum.all?(probabilities, &is_number/1),
      do: {:ok, probabilities},
      else: {:error, :no_answer}
  end

  @doc """
  What `asked`'s answers decide, as a hook says it, before what the run has
  read is weighed: `{:allow, :judged}` for an allow it holds back after
  outside content.
  """
  @spec judged([question()], {:ok, [float()]} | {:error, term()}) ::
          Wardrik.Hook.decision() | {:allow, :judged}
  def judged(asked, {:ok, probabilities}) do
    answers = Enum.zip(asked, probabilities)

    cond do
      denied = Enum.find(answers, &over?(&1, :deny)) -> {:deny, said(denied)}
      asking = Enum.find(answers, &over?(&1, :ask)) -> {:ask, said(asking)}
      allowed?(answers) -> {:allow, :judged}
      true -> :pass
    end
  end

  def judged(asked, {:error, reason}) do
    if Enum.any?(asked, &(&1.deny || &1.ask)),
      do: {:ask, "The judge could not answer (#{inspect(reason)}), so a person decides."},
      else: :pass
  end

  defp over?({question, probability}, effect) do
    threshold = Map.fetch!(question, effect)
    threshold != nil and probability >= threshold
  end

  defp allowed?(answers) do
    case Enum.filter(answers, fn {question, _p} -> question.allow end) do
      [] -> false
      allowing -> Enum.all?(allowing, fn {question, p} -> p < question.allow end)
    end
  end

  defp said({%{message: message}, _p}) when is_binary(message), do: message

  defp said({question, probability}),
    do: "Judged #{round(probability * 100)}% likely: #{question.question}"

  defp held({:allow, :judged}, run),
    do: if(@outside in labels(run), do: :pass, else: :allow)

  defp held(decision, _run), do: decision

  defp labels(%Wardrik.Run{labels: labels}), do: labels
  defp labels(nil), do: []

  # -- written down ------------------------------------------------------------

  @doc "The judge a map with string keys writes."
  @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
  def decode(%{} = fields) do
    with :ok <- known(fields, @keys, "judge"),
         {:ok, model} <- model(Map.get(fields, "model", "typesafe:jev-latest")),
         {:ok, questions} <- questions(Map.get(fields, "questions")) do
      {:ok, %__MODULE__{model: model, questions: questions}}
    end
  end

  def decode(_fields), do: {:error, "judge is a model and its questions"}

  @doc "The map `decode/1` reads `judge` back from."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = judge) do
    %{"model" => judge.model, "questions" => Enum.map(judge.questions, &written/1)}
  end

  defp written(question) do
    %{"question" => question.question}
    |> put("tools", question.tools != [] && Enum.map(question.tools, &to_string/1))
    |> put("deny", question.deny)
    |> put("ask", question.ask)
    |> put("allow", question.allow)
    |> put("message", question.message)
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp known(fields, keys, where) do
    case Map.keys(fields) -- keys do
      [] ->
        :ok

      [key | _] ->
        {:error, "#{where}.#{key} is not a setting; expected one of #{Enum.join(keys, ", ")}"}
    end
  end

  defp model(model) when is_binary(model) and model != "", do: {:ok, model}
  defp model(_model), do: {:error, "judge.model is a model, such as typesafe:jev-latest"}

  defp questions([_ | _] = questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {fields, n}, {:ok, read} ->
      case question(fields, "judge.questions[#{n}]") do
        {:ok, question} -> {:cont, {:ok, [question | read]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  defp questions(_questions), do: {:error, "judge.questions is a list of questions"}

  defp question(%{} = fields, where) do
    with :ok <- known(fields, @question_keys, where),
         {:ok, text} <- text(fields["question"], where),
         {:ok, tools} <- tools(Map.get(fields, "tools", []), where),
         {:ok, thresholds} <- thresholds(fields, where),
         {:ok, message} <- message(fields["message"], where) do
      {:ok, Map.merge(%{question: text, tools: tools, message: message}, thresholds)}
    end
  end

  defp question(_fields, where), do: {:error, "#{where} is a question, with what it decides"}

  defp text(text, _where) when is_binary(text) and text != "", do: {:ok, text}
  defp text(_text, where), do: {:error, "#{where}.question is the question to ask, yes or no"}

  defp tools(tools, where) when is_list(tools) do
    read = Enum.map(tools, &tool(&1, where))

    case Enum.find(read, &match?({:error, _message}, &1)) do
      nil -> {:ok, Enum.map(read, fn {:ok, pattern} -> pattern end)}
      error -> error
    end
  end

  defp tools(_tools, where), do: {:error, "#{where}.tools is a list of tool patterns"}

  defp tool(source, where) do
    case Pattern.parse(source) do
      {:ok, pattern} ->
        if Pattern.argument?(pattern),
          do: {:error, "#{where}.tools names tools alone, not what their calls act on or hold"},
          else: {:ok, pattern}

      {:error, message} ->
        {:error, "#{where}.tools: #{message}"}
    end
  end

  defp thresholds(fields, where) do
    given = for effect <- @effects, value = fields[Atom.to_string(effect)], do: {effect, value}

    cond do
      given == [] ->
        {:error, "#{where} decides nothing; give it deny, ask or allow"}

      bad = Enum.find(given, fn {_effect, value} -> not probability?(value) end) ->
        {:error, "#{where}.#{elem(bad, 0)} is a probability between 0 and 1"}

      not ordered?(given) ->
        {:error, "#{where} has allow at or below ask, and ask at or below deny"}

      true ->
        {:ok,
         Map.merge(
           %{deny: nil, ask: nil, allow: nil},
           Map.new(given, fn {e, v} -> {e, v / 1} end)
         )}
    end
  end

  defp probability?(value), do: is_number(value) and value > 0 and value < 1

  # The thresholds given, read from allow up to deny, rise.
  defp ordered?(given) do
    given
    |> Enum.sort_by(fn {effect, _value} ->
      Enum.find_index([:allow, :ask, :deny], &(&1 == effect))
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [{_low, low}, {_high, high}] -> low <= high end)
  end

  defp message(nil, _where), do: {:ok, nil}
  defp message(message, _where) when is_binary(message), do: {:ok, message}
  defp message(_message, where), do: {:error, "#{where}.message is what a person is asked"}
end
