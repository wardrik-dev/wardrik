defmodule Wardrik.Operations.Tokens do
  @moduledoc """
  The operations on the deployment's API tokens: making, listing and revoking them. A token is kept
  as the SHA-256 of its secret, and its secret is given once, as it's made. A token's resources
  that name an org, as `acme/agent/*`, name one the Wardrik's orgs know; one that leaves it open,
  as `*/agent/*`, reaches whichever do.
  """

  alias Wardrik.Authorizer
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Orgs
  alias Wardrik.Scope
  alias Wardrik.Statement
  alias Wardrik.Statements
  alias WardrikCore.Principal

  @lifetime 90 * 24 * 60 * 60
  @prefix "tokens/"

  @doc "Makes a token that acts for whoever makes it, and answers it with its secret, this once."
  @spec create(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create(%Scope{wardrik: wardrik, principal: principal} = scope, input) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, Map.get(input, "expires_in", @lifetime))

    with {:ok, statement} <- statement(input),
         :ok <- held(scope, statement),
         :ok <- bounded(scope, input["policy"]),
         :ok <- lasting(scope, expires),
         :ok <- known_orgs(wardrik, input["resources"]),
         :ok <- named_policy(wardrik, input["policy"] || scope.policy) do
      id = random(6)
      secret = "wrk_" <> id <> "_" <> random(32)

      token = %{
        "id" => id,
        "name" => input["name"],
        "principal" => %{"id" => principal.id},
        "statements" => [Statement.to_json(statement)],
        "policy" => input["policy"] || scope.policy,
        "expires" => DateTime.to_iso8601(expires),
        "created_at" => DateTime.to_iso8601(now)
      }

      {:ok, _vsn} =
        WardrikStore.put(store(wardrik), @prefix <> id, Map.put(token, "hash", hash(secret)))

      Changes.record_deployment(scope, "token.created", "tokens/" <> id, created(token))
      {:ok, %{"token" => shown(token), "secret" => secret}}
    end
  end

  defp within?(_token, nil), do: true

  defp within?(%{"statements" => statements}, patterns) do
    resources = for %{"resources" => resources} <- statements, resource <- resources, do: resource

    Enum.all?(resources, fn resource -> Enum.any?(patterns, &Statements.within?(resource, &1)) end)
  end

  defp held(scope, statement) do
    if Authorizer.holds?(scope, statement),
      do: :ok,
      else:
        {:error,
         Error.new(:forbidden, "A token can't do more than the one that makes it, on more of it.")}
  end

  defp bounded(%Scope{policy: nil}, _policy), do: :ok
  defp bounded(%Scope{policy: policy}, policy), do: :ok
  defp bounded(%Scope{policy: _held}, nil), do: :ok

  defp bounded(%Scope{policy: held}, _policy),
    do:
      {:error,
       Error.new(:forbidden, "A token made by one held to #{held} is held to #{held} too.")}

  defp lasting(%Scope{expires: nil}, _expires), do: :ok

  defp lasting(%Scope{expires: limit}, expires) do
    if DateTime.compare(expires, limit) == :gt,
      do:
        {:error,
         Error.new(
           :invalid_request,
           "A token can't outlast the one that makes it, which expires at #{DateTime.to_iso8601(limit)}."
         )},
      else: :ok
  end

  defp known_orgs(wardrik, resources) do
    resources
    |> Enum.map(&Orgs.org/1)
    |> Enum.reject(&String.contains?(&1, ["*", "?"]))
    |> Enum.uniq()
    |> Enum.map(&Orgs.known(wardrik, &1))
    |> Enum.find(:ok, &match?({:error, _error}, &1))
  end

  @doc "Lists every token, oldest first, never a secret, or those whose resources `resources` all cover."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, input) do
    store = store(wardrik)

    tokens =
      store
      |> WardrikStore.keys(@prefix)
      |> Enum.map(&WardrikStore.get(store, &1))
      |> Enum.sort_by(& &1["created_at"])
      |> Enum.filter(&within?(&1, input["resources"]))
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
    {:ok, expires, _offset} = DateTime.from_iso8601(token["expires"])

    %Scope{
      wardrik: wardrik.name,
      principal: %Principal{id: token["principal"]["id"]},
      grants: Enum.map(token["statements"], &Statement.from_json/1),
      policy: token["policy"],
      expires: expires
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
