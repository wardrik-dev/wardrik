defmodule WardrikGateway.Settings do
  @moduledoc false

  @limit NimbleOptions.new!(
           requests_per_minute: [type: :pos_integer, doc: "Calls a minute."],
           tokens_per_minute: [type: :pos_integer, doc: "Input and output tokens a minute."]
         )

  @schema NimbleOptions.new!(
            fallbacks: [
              type: {:map, :string, {:list, :string}},
              default: %{},
              doc: "Models to try, in order, when a call to the one it's keyed by fails."
            ],
            limits: [
              type: {:map, :string, :keyword_list},
              default: %{},
              doc: """
              Per provider, as `"anthropic"`: `requests_per_minute` and `tokens_per_minute`.
              A provider with none isn't limited.
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
                  doc: "Milliseconds it stays open before one call tries the model again."
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

  @doc "Returns the settings `opts` give. Raises `ArgumentError` on a bad one."
  @spec new!(keyword()) :: map()
  def new!(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %{
      fallbacks:
        Map.new(opts[:fallbacks], fn {model, rest} -> {spec!(model), Enum.map(rest, &spec!/1)} end),
      limits:
        Map.new(opts[:limits], fn {provider, limit} ->
          {provider, NimbleOptions.validate!(limit, @limit)}
        end),
      breaker: Map.new(opts[:breaker]),
      wait: opts[:wait]
    }
  end

  # The agent's model arrives as the catalog spells it, so fallbacks are keyed the same way.
  defp spec!(model) do
    case ReqLLM.model(model) do
      {:ok, found} -> LLMDB.Model.spec(found)
      {:error, _reason} -> raise ArgumentError, "#{model} isn't a model the catalog knows."
    end
  end
end
