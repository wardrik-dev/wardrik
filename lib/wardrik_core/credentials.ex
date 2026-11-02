defmodule WardrikCore.Credentials do
  @moduledoc """
  Gives tools the credentials of whoever the turn acts for.

  Use it when a tool acts as a person, with their own token. For your own API keys, see
  `WardrikCore.Keys`.

      defmodule MyApp.Vault do
        @behaviour WardrikCore.Credentials

        @impl true
        def resolve(%{principal: nil}, _opts), do: {:error, "There's no one to act for."}

        def resolve(%{name: name, principal: %WardrikCore.Principal{id: id}}, _opts) do
          case MyApp.Tokens.get(id, name) do
            %{access_token: token} -> {:ok, token}
            nil -> {:authorize, "https://app.example.com/connect/\#{name}"}
          end
        end
      end

  Give it to an agent as `credentials: {MyApp.Vault, opts}`. A tool then fetches what it needs:

      run: fn %{title: title}, context ->
        with {:ok, token} <- WardrikCore.Credentials.fetch(context, "github") do
          GitHub.create_issue(token, title)
        end
      end

  If the person hasn't granted the credential yet, the call parks on a
  `WardrikCore.Authorization`. Once they've signed in, resume the turn and the call runs again.

  If a service refuses a credential, such as with a 401, call `refused/2` and fetch again. The
  module should return a fresh credential, or a new sign-in.

  Credentials are never kept in the context, so they're never saved or emitted. Keep them out of
  private data and attributes too.

  See the [Credentials](credentials.html) guide.
  """
  alias WardrikCore.Authorization
  alias WardrikCore.Context
  alias WardrikCore.Credentials.Request

  @doc """
  Returns the credential the request names, for its principal.

    * `{:ok, secret}` - the credential.
    * `{:authorize, url}` - the person must sign in at `url` first.
    * `{:error, reason}` - it can't be given.
  """
  @callback resolve(Request.t(), opts :: term()) ::
              {:ok, secret :: term()} | {:authorize, url :: String.t()} | {:error, term()}

  @doc "Called when a service refused the credential the request names. Optional."
  @callback refused(Request.t(), opts :: term()) :: :ok

  @optional_callbacks refused: 2

  @doc """
  Fetches the credential `name` for whoever the turn acts for.

  Returns `{:park, authorization}` if the person must sign in first, and `{:error, reason}` if the
  agent has no credentials module. See `WardrikCore.Context.acting_for/1`.
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

  @doc "Tells the credentials module that a service refused the credential `name`, so it isn't given again."
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
