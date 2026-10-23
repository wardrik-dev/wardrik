defmodule Wardrik.Operations.Tokens do
  @moduledoc """
  The operations on the deployment's API tokens: making, listing and revoking them. A token is kept
  as the SHA-256 of its secret, and its secret is given once, as it's made.
  """

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Scope
  alias Wardrik.Statement
  alias WardrikCore.Principal

  @lifetime 90 * 24 * 60 * 60
  @prefix "tokens/"

  @doc "Makes a token that acts for whoever makes it, and answers it with its secret, this once."
  @spec create(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create(%Scope{wardrik: wardrik, principal: principal} = scope, input) do
    with {:ok, statement} <- statement(input),
         :ok <- named_policy(wardrik, input["policy"] || scope.policy) do
      id = random(6)
      secret = "wrk_" <> id <> "_" <> random(32)
      now = DateTime.utc_now()

      token = %{
        "id" => id,
        "name" => input["name"],
        "principal" => %{"id" => principal.id},
        "statements" => [Statement.to_json(statement)],
        "policy" => input["policy"] || scope.policy,
        "expires" =>
          now |> DateTime.add(Map.get(input, "expires_in", @lifetime)) |> DateTime.to_iso8601(),
        "created_at" => DateTime.to_iso8601(now)
      }

      {:ok, _vsn} =
        WardrikStore.put(store(wardrik), @prefix <> id, Map.put(token, "hash", hash(secret)))

      Changes.record_deployment(scope, "token.created", "tokens/" <> id, created(token))
      {:ok, %{"token" => shown(token), "secret" => secret}}
    end
  end

  @doc "Lists every token, oldest first, never a secret."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, _input) do
    store = store(wardrik)

    tokens =
      store
      |> WardrikStore.keys(@prefix)
      |> Enum.map(&WardrikStore.get(store, &1))
      |> Enum.sort_by(& &1["created_at"])
      |> Enum.map(&shown/1)

    {:ok, %{"tokens" => tokens}}
  end

  @doc "Revokes a token, which is refused from then on, and answers it as it was."
  @spec revoke(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def revoke(%Scope{wardrik: wardrik} = scope, %{"token" => id}) do
    case WardrikStore.get(store(wardrik), @prefix <> id) do
      nil ->
        {:error, Error.new(:not_found, "There's no token #{id}.")}

      token ->
        :ok = WardrikStore.delete(store(wardrik), @prefix <> id)

        Changes.record_deployment(scope, "token.revoked", "tokens/" <> id, %{
          "token" => %{"id" => id}
        })

        {:ok, shown(token)}
    end
  end

  @doc "Returns the scope a token's `secret` acts in, or an `unauthorized` error."
  @spec authenticate(Wardrik.t(), String.t()) :: {:ok, Scope.t()} | {:error, Error.t()}
  def authenticate(wardrik, "wrk_" <> rest = secret) do
    with [id, _random] <- String.split(rest, "_", parts: 2),
         %{} = token <- WardrikStore.get(store(wardrik), @prefix <> id),
         true <- :crypto.hash_equals(token["hash"], hash(secret)),
         true <- current?(token) do
      {:ok, scoped(wardrik, token)}
    else
      _refused -> unauthorized()
    end
  end

  def authenticate(_wardrik, _secret), do: unauthorized()

  defp statement(%{"roles" => names, "resources" => resources}) do
    roles = Enum.map(names, &Statement.role/1)

    if Enum.member?(roles, :error),
      do:
        {:error,
         Error.new(
           :invalid_request,
           "A token's roles are reader, messenger, approver, definer or owner."
         )},
      else:
        {:ok,
         Statement.new(roles: Enum.map(roles, fn {:ok, role} -> role end), resources: resources)}
  end

  defp named_policy(_wardrik, nil), do: :ok

  defp named_policy(wardrik, name) do
    if Map.has_key?(wardrik.policies, name),
      do: :ok,
      else: {:error, Error.new(:invalid_request, "There's no policy #{name} here.")}
  end

  defp scoped(wardrik, token) do
    %Scope{
      wardrik: wardrik.name,
      principal: %Principal{id: token["principal"]["id"]},
      grants: Enum.map(token["statements"], &Statement.from_json/1),
      policy: token["policy"]
    }
  end

  defp current?(%{"expires" => expires}) do
    {:ok, expires, _offset} = DateTime.from_iso8601(expires)
    DateTime.after?(expires, DateTime.utc_now())
  end

  defp unauthorized,
    do: {:error, Error.new(:unauthorized, "The token isn't one, or has expired.")}

  defp shown(token),
    do: token |> Map.delete("hash") |> Map.reject(fn {_key, value} -> is_nil(value) end)

  defp created(token),
    do: %{"token" => Map.take(token, ["id", "name"]), "statements" => token["statements"]}

  defp hash(secret), do: :crypto.hash(:sha256, secret)
  defp random(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
