defmodule Wardrik.LLM.Key do
  @moduledoc """
  A model provider's key, for a request that has none: from the
  `Wardrik.Credentials` of the host it is made on, as the deployment's own
  secret named for the provider, such as `ANTHROPIC_API_KEY`.

  A key the request already carries, as a dispatch supplies one, and one
  ReqLLM finds in its config or the environment, are left to stand, so the
  host's credentials are asked only where nothing else holds one. The key
  rides the request it is for alone, never the node's config, where
  anything the node runs could read it.
  """

  alias Wardrik.LLM.Request

  @doc "`request`, with the key the credentials of `host` hold for its provider where it needs one."
  @spec put(Request.t(), Wardrik.Host.t()) :: Request.t()
  def put(%Request{model_spec: spec, opts: opts} = request, %Wardrik.Host{} = host) do
    with {:ok, %LLMDB.Model{provider: provider}} <- ReqLLM.model(spec),
         {:error, _none} <- ReqLLM.Keys.get(provider, opts),
         {:ok, key} <-
           Wardrik.Credentials.key(
             Wardrik.Host.credentials(host),
             ReqLLM.Keys.env_var_name(provider)
           ) do
      Request.put_opts(request, api_key: key)
    else
      _held_or_unheld -> request
    end
  end
end
