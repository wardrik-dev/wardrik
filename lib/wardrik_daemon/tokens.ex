defmodule WardrikDaemon.Tokens do
  @schema NimbleOptions.new!(
            name: [type: :string, required: true, doc: "What it's for, to tell tokens apart."],
            subject: [
              type: {:custom, __MODULE__, :subject, []},
              required: true,
              doc: "Who it authenticates as: `user:ID`, or `agent:ID` for an agent's own."
            ],
            groups: [
              type: {:list, :string},
              default: [],
              doc: "The groups a `user:` token's principal is in, which bindings may name."
            ],
            expires: [type: {:struct, DateTime}, required: true, doc: "When it stops working."]
          )

  @moduledoc """
  Keeps the secrets the HTTP API is reached with. `WardrikDaemon.Authenticator` checks them.

      {:ok, %{token: token, secret: secret}} =
        WardrikDaemon.Tokens.create(store,
          name: "ana's laptop",
          subject: "user:ana",
          groups: ["payments-eng"],
          expires: DateTime.add(DateTime.utc_now(), 30, :day)
        )

  A secret looks like `wdk_<id>_<random>`. It's shown once, as `create/2` returns it: only its
  SHA-256 hash is kept, so neither the store nor `list/1` holds it. `verify/2` compares hashes in
  constant time.

  The admin issues the rest at `/v1/tokens`, as `wardrik token create` does. See
  `WardrikDaemon.HTTP`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias WardrikDaemon.Tokens.Token

  @prefix "tokens/"

  @doc """
  Makes a token in `store`. Returns it, with its secret, which isn't kept, or why the options
  don't read.
  """
  @spec create(WardrikStore.t(), keyword()) ::
          {:ok, %{token: Token.t(), secret: String.t()}}
          | {:error, NimbleOptions.ValidationError.t()}
  def create(store, opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      id = 10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
      secret = "wdk_#{id}_#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      token = struct!(Token, [id: id] ++ opts)

      {:ok, _vsn} = WardrikStore.put(store, @prefix <> id, %{token: token, hash: hash(secret)})
      {:ok, %{token: token, secret: secret}}
    end
  end

  @doc "Returns the tokens in `store`, by ID, without their secrets."
  @spec list(WardrikStore.t()) :: [Token.t()]
  def list(store),
    do: for({_key, %{token: token}, _vsn} <- WardrikStore.entries(store, @prefix), do: token)

  @doc "Stops the token `id` working. Returns `:ok`, also when there's none."
  @spec revoke(WardrikStore.t(), String.t()) :: :ok
  def revoke(store, id), do: WardrikStore.delete(store, @prefix <> id)

  @doc "Returns the token `secret` is, unless it's unknown, revoked or expired."
  @spec verify(WardrikStore.t(), String.t()) :: {:ok, Token.t()} | :error
  def verify(store, secret) do
    with ["wdk", id, _random] <- String.split(secret, "_", parts: 3),
         %{token: token, hash: hash} <- WardrikStore.get(store, @prefix <> id),
         true <- Plug.Crypto.secure_compare(hash(secret), hash),
         :gt <- DateTime.compare(token.expires, DateTime.utc_now()) do
      {:ok, token}
    else
      _refused -> :error
    end
  end

  @doc false
  def subject("user:" <> id = subject) when id not in ["", "deployment"], do: {:ok, subject}
  def subject("agent:" <> id = subject) when id != "", do: {:ok, subject}
  def subject(other), do: {:error, "expected user:ID or agent:ID, got: #{inspect(other)}"}

  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
