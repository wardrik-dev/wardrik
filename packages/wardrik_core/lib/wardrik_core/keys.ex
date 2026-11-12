defmodule WardrikCore.Keys do
  @moduledoc """
  Gives your code its API keys, such as a model provider's.

      defmodule MyApp.Keys do
        @behaviour WardrikCore.Keys

        @impl true
        def fetch(%WardrikCore.Keys.Request{name: name, principal: principal}, _opts) do
          case MyApp.Secrets.key(principal.id, name) do
            nil -> {:error, :not_found}
            key -> {:ok, key}
          end
        end
      end

  Give it to an agent as `keys: {MyApp.Keys, opts}`, or to Wardrik as `key_source:`. Your code
  fetches what it needs:

      with {:ok, key} <- WardrikCore.Keys.fetch(context, "BRAVE_API_KEY") do
        Brave.search(key, query)
      end

    * Each model call fetches its provider's key, such as `ANTHROPIC_API_KEY`. With none, ReqLLM
      uses its config or the environment.
    * Keys are never saved or emitted.
    * A person's own tokens belong in `WardrikCore.Credentials`.
  """

  alias WardrikCore.Context
  alias WardrikCore.Keys.Request

  @doc "Returns the key the request names, `{:error, :not_found}`, or why it can't."
  @callback fetch(Request.t(), opts :: term()) ::
              {:ok, String.t()} | {:error, :not_found} | {:error, term()}

  @doc "Fetches the key `name` for the agent. Returns `{:error, :not_found}` if there's none."
  @spec fetch(Context.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(%Context{keys: nil}, _name), do: {:error, :not_found}

  def fetch(%Context{keys: {module, opts}, principal: principal}, name),
    do: module.fetch(%Request{name: name, principal: principal}, opts)

  def fetch(%Context{keys: module, principal: principal}, name),
    do: module.fetch(%Request{name: name, principal: principal}, [])

  @doc "Returns `[api_key: key]` for `model`'s provider, or `[]` if there's no key."
  @spec model_options(Context.t(), LLMDB.Model.t() | String.t()) :: keyword()
  def model_options(%Context{keys: nil}, _model), do: []

  def model_options(context, model) do
    with name when is_binary(name) <- key_name(model),
         {:ok, key} <- fetch(context, name) do
      [api_key: key]
    else
      _none -> []
    end
  end

  @doc """
  Returns the name of the key `model`'s provider takes, or `nil`.

      WardrikCore.Keys.key_name("zai:glm-5.1")
      #=> "ZAI_API_KEY"
  """
  @spec key_name(LLMDB.Model.t() | String.t()) :: String.t() | nil
  def key_name(%{provider: provider}) when is_atom(provider), do: env_key(provider)

  def key_name(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, _model] -> provider |> existing_atom() |> env_key()
      _unnamed -> nil
    end
  end

  def key_name(_model), do: nil

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp env_key(nil), do: nil

  defp env_key(provider) do
    with {:ok, module} <- ReqLLM.provider(provider),
         true <- function_exported?(module, :default_env_key, 0) do
      module.default_env_key()
    else
      _unknown -> nil
    end
  end
end
