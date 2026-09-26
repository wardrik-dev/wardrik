defmodule Wardrik.Call.Model do
  @moduledoc """
  The model a `Wardrik.Call` goes to: which model, roughly how many tokens it
  sends, the tools it offers, and, once it has been made, what it used, as
  `Wardrik.LLM.Usage` reports it.

  A hook sees no conversation and no options, so nothing it is shown carries a
  credential.
  """

  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens

  @enforce_keys [:model_spec, :input_tokens, :tools]
  defstruct [:model_spec, :input_tokens, :tools, :usage]

  @type t() :: %__MODULE__{
          model_spec: term(),
          input_tokens: non_neg_integer(),
          tools: [String.t()],
          usage: map() | nil
        }

  @doc "The model `request` goes to."
  @spec new(Request.t()) :: t()
  def new(%Request{} = request) do
    %__MODULE__{
      model_spec: request.model_spec,
      input_tokens: Tokens.request(request),
      tools: request.opts |> Keyword.get(:tools, []) |> Enum.map(& &1.name)
    }
  end

  @doc "The model's name as a person reads it: `anthropic:claude-sonnet-5`."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{model_spec: spec}) when is_binary(spec), do: spec

  def name(%__MODULE__{model_spec: {provider, opts}}) when is_atom(provider),
    do: "#{provider}:#{opts[:model] || opts[:id]}"

  def name(%__MODULE__{model_spec: spec}), do: inspect(spec)
end
