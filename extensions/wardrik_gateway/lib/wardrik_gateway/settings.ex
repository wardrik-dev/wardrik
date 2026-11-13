defmodule WardrikGateway.Settings do
  @moduledoc false

  @limit NimbleOptions.new!(
           requests_per_minute: [type: :pos_integer, doc: "Calls a minute."],
           tokens_per_minute: [type: :pos_integer, doc: "Input and output tokens a minute."]
         )

  @schema NimbleOptions.new!(
            fallbacks: [
              type: {:custom, __MODULE__, :fallbacks, []},
              default: %{},
              doc: "Models to call, in order, when a call to the key's model fails."
            ],
            limits: [
              type: {:custom, __MODULE__, :limits, []},
              default: %{},
              doc: """
              `requests_per_minute` and `tokens_per_minute`, by provider, as `"anthropic"`.
              Providers not listed are unlimited.
              """
            ],
            breaker: [
              type: :keyword_list,
              default: [],
              doc: "When a model is skipped.",
              keys: [
                failures: [type: :pos_integer, default: 5, doc: "Failures that open it."],
                within: [
                  type: :non_neg_integer,
                  default: 30_000,
                  doc: "Milliseconds the failures fall within."
                ],
                open_for: [
                  type: :non_neg_integer,
                  default: 30_000,
                  doc: "Milliseconds before one call is let through to test the model."
                ]
              ]
            ],
            wait: [
              type: :non_neg_integer,
              default: :timer.minutes(10),
              doc:
                "The longest a call waits, in milliseconds, for room or for a model to come back."
            ]
          )

  @doc "Returns the schema of the gateway's settings."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc "Returns the settings `opts` give. Raises `NimbleOptions.ValidationError` on a bad one."
  @spec new!(keyword()) :: map()
  def new!(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %{
      fallbacks: opts[:fallbacks],
      limits: opts[:limits],
      breaker: Map.new(opts[:breaker]),
      wait: opts[:wait]
    }
  end

  @doc false
  @spec fallbacks(term()) :: {:ok, %{String.t() => [String.t()]}} | {:error, String.t()}
  def fallbacks(fallbacks) when is_map(fallbacks) do
    Enum.reduce_while(fallbacks, {:ok, %{}}, fn
      {model, rest}, {:ok, done} when is_binary(model) and is_list(rest) ->
        case specs([model | rest]) do
          {:ok, [model | rest]} -> {:cont, {:ok, Map.put(done, model, rest)}}
          error -> {:halt, error}
        end

      {model, _rest}, _done ->
        {:halt, {:error, "#{inspect(model)}'s fallbacks are a list of models"}}
    end)
  end

  def fallbacks(other), do: {:error, "fallbacks is a map of models, got: #{inspect(other)}"}

  @doc false
  @spec limits(term()) :: {:ok, %{String.t() => keyword()}} | {:error, String.t()}
  def limits(limits) when is_map(limits) do
    Enum.reduce_while(limits, {:ok, %{}}, fn {provider, limit}, {:ok, done} ->
      case NimbleOptions.validate(limit, @limit) do
        {:ok, limit} -> {:cont, {:ok, Map.put(done, to_string(provider), limit)}}
        {:error, error} -> {:halt, {:error, "#{provider}: #{Exception.message(error)}"}}
      end
    end)
  end

  def limits(other), do: {:error, "limits is a map of providers, got: #{inspect(other)}"}

  # The agent's model arrives as the catalog spells it, so fallbacks are keyed the same way.
  defp specs(models) do
    found = Enum.map(models, &{&1, ReqLLM.model(&1)})

    case Enum.find(found, &match?({_model, {:error, _reason}}, &1)) do
      nil -> {:ok, Enum.map(found, fn {_model, {:ok, model}} -> LLMDB.Model.spec(model) end)}
      {unknown, _error} -> {:error, "#{inspect(unknown)} isn't a model the catalog knows"}
    end
  end
end
