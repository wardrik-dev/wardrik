defmodule Wardrik.LLM.Request do
  @moduledoc """
  One model call, as a value, before it is made.

  The turn builds one of these and hands it to `Wardrik.LLM.Dispatch`, which is
  what lets a host route the call, supply the key it runs under, or refuse it,
  without the turn knowing that any of that happened.

  Everything `ReqLLM.stream_text/3` takes is here, so a dispatch that rewrites
  a request cannot rewrite anything the turn depends on, and with it the tries
  of the call that failed before this one, newest first, as
  `Wardrik.LLM.Attempt`s: empty on a call's first try. A dispatch reads them to
  send the next try elsewhere; see `Wardrik.LLM.Retry`.
  """

  alias Wardrik.LLM.Attempt
  alias Wardrik.LLM.Config

  @enforce_keys [:model_spec, :context, :opts]
  defstruct [:model_spec, :context, :opts, attempts: []]

  @typedoc "A model call: which model, what conversation, the options it runs under, and its failed tries."
  @type t() :: %__MODULE__{
          model_spec: term(),
          context: ReqLLM.Context.t(),
          opts: keyword(),
          attempts: [Attempt.t()]
        }

  @doc """
  Builds the request a config and context describe.

  `:tools` and `:system_prompt` are taken from the config's own fields rather
  than from `:generation`, which is why a caller cannot set them there.
  """
  @spec new(Config.t(), ReqLLM.Context.t()) :: t()
  def new(%Config{} = config, %ReqLLM.Context{} = context) do
    %__MODULE__{
      model_spec: config.model_spec,
      context: context,
      opts: opts(config)
    }
  end

  defp opts(%Config{} = config) do
    config.generation
    |> Keyword.put(:tools, Config.tools(config))
    |> put_system(config.system)
  end

  defp put_system(opts, nil), do: opts
  defp put_system(opts, system), do: Keyword.put(opts, :system_prompt, system)

  @doc """
  Adds or replaces options on a request.

  What a host reaches for in `c:Wardrik.LLM.Dispatch.admit/2` to supply the key a
  call runs under, or the endpoint it goes to.

      Wardrik.LLM.Request.put_opts(request, api_key: key, base_url: gateway)
  """
  @spec put_opts(t(), keyword()) :: t()
  def put_opts(%__MODULE__{} = request, opts) when is_list(opts) do
    %{request | opts: Keyword.merge(request.opts, opts)}
  end

  @doc "The request with `attempt`, a try of it that failed, added to its attempts."
  @spec failed(t(), Attempt.t()) :: t()
  def failed(%__MODULE__{attempts: attempts} = request, %Attempt{} = attempt),
    do: %{request | attempts: [attempt | attempts]}

  @doc "Sends this request to a different model."
  @spec put_model(t(), term()) :: t()
  def put_model(%__MODULE__{} = request, model_spec) do
    %{request | model_spec: model_spec}
  end
end
