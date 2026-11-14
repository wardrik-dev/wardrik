defmodule Wardrik.Credentials do
  @moduledoc """
  Gives tools the tokens of the person a turn acts for. For your own API keys, see
  `Wardrik.Keys`.

      defmodule MyApp.Vault do
        @behaviour Wardrik.Credentials

        @impl true
        def resolve(%{principal: nil}, _opts), do: {:error, "There's no one to act for."}

        def resolve(%{name: name, principal: %{id: id}}, _opts) do
          case MyApp.Tokens.get(id, name) do
            nil -> {:authorize, "https://app.example.com/connect/\#{name}"}
            token -> {:ok, token}
          end
        end
      end

  Give it to an agent as `credentials: {MyApp.Vault, opts}`. A tool fetches what it needs:

      with {:ok, token} <- Wardrik.Credentials.fetch(context, "github") do
        GitHub.create_issue(token, title)
      end

    * `{:authorize, url}` parks the call on a `Wardrik.Credentials.Authorization`.
    * Call `refused/2` when a service rejects a token, then fetch again.
    * Tokens are never saved or emitted. Keep them out of private data and attributes.

  See the [Credentials](credentials.html) guide.
  """
  alias Wardrik.Context
  alias Wardrik.Credentials.Authorization
  alias Wardrik.Credentials.Request

  @doc """
  Returns the credential the request names: `{:ok, secret}`, `{:authorize, url}` for a sign-in
  first, or `{:error, reason}`.
  """
  @callback resolve(Request.t(), opts :: term()) ::
              {:ok, secret :: term()} | {:authorize, url :: String.t()} | {:error, term()}

  @doc "Called when a service refused the credential the request names. Optional."
  @callback refused(Request.t(), opts :: term()) :: :ok

  @optional_callbacks refused: 2

  @doc """
  Fetches the credential `name` for whoever the turn acts for.

  Returns `{:park, authorization}` if the person must sign in first, and `{:error, reason}` if the
  agent has no credentials module.
  """
  @spec fetch(Context.t(), String.t()) ::
          {:ok, term()} | {:park, Authorization.t()} | {:error, term()}
  def fetch(%Context{credentials: nil}, name), do: {:error, "No credentials to give #{name}."}

  def fetch(%Context{credentials: entry} = context, name) do
    {module, opts} = Context.entry(entry)
    request = %Request{name: name, principal: Context.acting_for(context)}

    request
    |> module.resolve(opts)
    |> fetched(request)
  end

  @doc "Tells the credentials module that a service refused the credential `name`."
  @spec refused(Context.t(), String.t()) :: :ok
  def refused(%Context{credentials: nil}, _name), do: :ok

  def refused(%Context{credentials: entry} = context, name) do
    {module, opts} = Context.entry(entry)
    request = %Request{name: name, principal: Context.acting_for(context)}

    if Code.ensure_loaded?(module) and function_exported?(module, :refused, 2),
      do: module.refused(request, opts),
      else: :ok
  end

  defp fetched({:authorize, url}, %Request{name: name, principal: principal}),
    do: {:park, %Authorization{url: url, credential: name, principal: principal}}

  defp fetched(resolved, _request), do: resolved
end
