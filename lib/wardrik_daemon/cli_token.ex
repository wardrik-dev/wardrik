defmodule WardrikDaemon.CLIToken do
  @moduledoc false

  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Tokens

  @doc "Revokes the token at `path`, makes a new one in `store`, and writes it to `path` with `url`."
  @spec issue(WardrikStore.t(), Path.t(), String.t()) :: :ok
  def issue(store, path, url) do
    revoked(store, path)

    {:ok, %{token: token, secret: secret}} =
      Tokens.create(store,
        name: "wardrik command",
        subject: "user:" <> Access.admin(),
        expires: DateTime.add(DateTime.utc_now(), 365, :day)
      )

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{id: token.id, secret: secret, url: url}))
    File.chmod!(path, 0o600)
  end

  @doc "Returns the `url` and `secret` of the token at `path`, or `:error` if there's none."
  @spec read(Path.t()) :: {:ok, %{url: String.t(), secret: String.t()}} | :error
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"url" => url, "secret" => secret}} <- JSON.decode(text) do
      {:ok, %{url: url, secret: secret}}
    else
      _missing -> :error
    end
  end

  defp revoked(store, path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"id" => id}} <- JSON.decode(text),
         do: Tokens.revoke(store, id)
  end
end
