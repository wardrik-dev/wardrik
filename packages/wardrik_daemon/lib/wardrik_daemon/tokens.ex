defmodule WardrikDaemon.Tokens do
  @schema NimbleOptions.new!(
            name: [type: :string, required: true, doc: "What it's for, to tell tokens apart."],
            subject: [
              type: {:custom, __MODULE__, :subject, []},
              required: true,
              doc:
                "Who it authenticates as: a user, as `user:acme/@ana`, or `agent:ID` for an " <>
                  "agent's own."
            ],
            groups: [
              type: {:list, :string},
              default: [],
              doc: "The groups a `user:` token's principal is in, which bindings may name."
            ],
            expires: [type: {:struct, DateTime}, required: true, doc: "When it stops working."]
          )

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  The tokens the HTTP API takes. `WardrikDaemon.Authenticator` checks them.

      {:ok, %{token: token, secret: secret}} =
        WardrikDaemon.Tokens.create(store,
          name: "ana's laptop",
          subject: "user:payments/@ana",
          groups: ["payments-eng"],
          expires: DateTime.add(DateTime.utc_now(), 30, :day)
        )

    * A secret looks like `wdk_<id>_<random>` and is shown once. Only its SHA-256 hash is kept.
    * The admin issues tokens with `wardrik token create`, or at `/v1/tokens`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Tokens.Token

  @prefix "tokens/"

  @doc "Makes a token. Returns it with its secret, which isn't kept."
  @spec create(Wardrik.Store.t(), keyword()) ::
          {:ok, %{token: Token.t(), secret: String.t()}}
          | {:error, NimbleOptions.ValidationError.t()}
  def create(store, opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      id = Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
      secret = "wdk_#{id}_#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"
      token = struct!(Token, [id: id] ++ opts)

      {:ok, _vsn} = Wardrik.Store.put(store, @prefix <> id, %{token: token, hash: hash(secret)})
      {:ok, %{token: token, secret: secret}}
    end
  end

  @expires_in 30 * 24 * 3600

  @doc """
  Creates a token from `input`, in the format `POST /v1/tokens` accepts. Returns the token as
  JSON, including its secret.

  The token expires after 30 days. Set `"expires_in"` to change this.
  """
  @spec issue(Wardrik.Store.t(), map()) :: {:ok, map()} | {:error, Wardrik.Error.t()}
  def issue(store, input) do
    expires = DateTime.add(DateTime.utc_now(), Map.get(input, "expires_in", @expires_in), :second)

    opts = [
      name: input["name"],
      subject: input["subject"],
      groups: Map.get(input, "groups", []),
      expires: expires
    ]

    case create(store, opts) do
      {:ok, %{token: created, secret: secret}} -> {:ok, Map.put(json(created), "secret", secret)}
      {:error, error} -> {:error, Wardrik.Error.new(:invalid_request, Exception.message(error))}
    end
  end

  @doc "Returns `token` as JSON, in the format the HTTP API uses. The secret is not included."
  @spec json(Token.t()) :: map()
  def json(token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "subject" => token.subject,
      "groups" => token.groups,
      "expires" => DateTime.to_iso8601(token.expires)
    }
  end

  @doc "Returns the tokens in `store`, by ID, without their secrets."
  @spec list(Wardrik.Store.t()) :: [Token.t()]
  def list(store),
    do: for({_key, %{token: token}, _vsn} <- Wardrik.Store.entries(store, @prefix), do: token)

  @doc "Stops the token `id` working. Returns `:ok`, also when there's none."
  @spec revoke(Wardrik.Store.t(), String.t()) :: :ok
  def revoke(store, id), do: Wardrik.Store.delete(store, @prefix <> id)

  @doc "Returns the token `secret` is, unless it's unknown, revoked or expired."
  @spec verify(Wardrik.Store.t(), String.t()) :: {:ok, Token.t()} | :error
  def verify(store, secret) do
    with ["wdk", id, _random] <- String.split(secret, "_", parts: 3),
         %{token: token, hash: hash} <- Wardrik.Store.get(store, @prefix <> id),
         true <- Plug.Crypto.secure_compare(hash(secret), hash),
         :gt <- DateTime.compare(token.expires, DateTime.utc_now()) do
      {:ok, token}
    else
      _refused -> :error
    end
  end

  # A user is a person in an org, or the admin. Never an org itself, which would own its agents.
  @doc false
  @spec subject(term()) :: {:ok, String.t()} | {:error, String.t()}
  def subject("user:" <> id = subject) do
    if id == Access.admin() or Owners.user?(id), do: {:ok, subject}, else: refused(subject)
  end

  def subject("agent:" <> id = subject) when id != "", do: {:ok, subject}
  def subject(other), do: refused(other)

  defp refused(subject),
    do: {:error, "expected a user, as user:acme/@ana, or agent:ID, got: #{inspect(subject)}"}

  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
