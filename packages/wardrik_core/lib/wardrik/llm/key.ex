defmodule Wardrik.LLM.Key do
  @moduledoc """
  A model provider's key, for a request that has none: from the
  `Wardrik.Credentials` of the host it is made on, as the secret the host's
  `Wardrik.LLM.Client` names for the model, such as `ANTHROPIC_API_KEY`.

  A key the request already carries, as a dispatch supplies one, and one
  the client finds in its own config or the environment, are left to stand,
  so the host's credentials are asked only where nothing else holds one. The
  key rides the request it is for alone, never the node's config, where
  anything the node runs could read it.
  """

  alias Wardrik.Host
  alias Wardrik.LLM.Client
  alias Wardrik.LLM.Model
  alias Wardrik.LLM.Request

  @doc "`request`, with the key the credentials of `host` hold for its model where it needs one."
  @spec put(Request.t(), Host.t()) :: Request.t()
  def put(%Request{model_spec: spec, opts: opts} = request, %Host{} = host) do
    with nil <- opts[:api_key],
         {:ok, %Model{key: name}} when is_binary(name) <- Client.model(Host.llm(host), spec),
         {:ok, key} <- Wardrik.Credentials.key(Host.credentials(host), name) do
      Request.put_opts(request, api_key: key)
    else
      _held_or_unheld -> request
    end
  end
end
