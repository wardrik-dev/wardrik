defmodule WardrikCore.Keys do
  @moduledoc """
  Gives your code the API keys it calls services with, such as a model provider's or a search
  API's.

      defmodule MyApp.Keys do
        @behaviour WardrikCore.Keys

        @impl true
        def fetch(%WardrikCore.Keys.Request{name: name, principal: principal}, _opts),
          do: MyApp.Vault.key(principal, name)
      end

  Give it to an agent as `keys: {MyApp.Keys, opts}`. Keys are fetched by name, for the agent's
  `WardrikCore.Principal`, so an org can bring its own. A capability or middleware fetches what it
  needs:

      with {:ok, key} <- WardrikCore.Keys.fetch(context, "BRAVE_API_KEY") do
        Brave.search(key, query)
      end

  ## Model calls

  Every model call fetches its provider's key by the name ReqLLM gives it, such as
  `ANTHROPIC_API_KEY`, and passes it to that call only. If there's no keys module, or it has no
  such key, ReqLLM finds one in its config or the environment.

  ## Keys and credentials

  Keys are for the code you install. A tool that acts for a person uses their credentials instead,
  from `WardrikCore.Credentials`. That way nothing an agent's owner configures can read your keys.

  Keys are never kept in the context, so they're never saved or emitted.
  """

  alias WardrikCore.Context
  alias WardrikCore.Keys.Request

  @doc "Returns the key the request names, for its principal, or `:error` if there's none."
  @callback fetch(Request.t(), opts :: term()) :: {:ok, String.t()} | :error

  @doc "Fetches the key `name` for the agent's principal. Returns `:error` if there's none."
  @spec fetch(Context.t(), String.t()) :: {:ok, String.t()} | :error
  def fetch(%Context{keys: nil}, _name), do: :error

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
