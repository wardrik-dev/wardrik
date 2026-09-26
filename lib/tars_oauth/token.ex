defmodule TarsOAuth.Token do
  @moduledoc """
  What an authorization server handed back, and when it stops being useful.

  Written to `TarsVault` as JSON and read back the same way, so a token
  survives a restart sealed rather than in the clear. `inspect/1` shows the
  scope and the expiry, never the token.

  A token remembers where it came from, as `bind/3` writes it: the issuer,
  the token endpoint, the client it was issued to and the resource it is
  for. It is renewed there, and nowhere else.
  """

  @enforce_keys [:access_token]
  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :scope,
    :issuer,
    :token_endpoint,
    :client_id,
    :resource,
    type: "Bearer"
  ]

  @typedoc "An access token, and whatever came with it."
  @type t() :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: integer() | nil,
          scope: String.t() | nil,
          issuer: String.t() | nil,
          token_endpoint: String.t() | nil,
          client_id: String.t() | nil,
          resource: String.t() | nil,
          type: String.t()
        }

  @bound ~w(issuer token_endpoint client_id resource)a

  # A token about to expire is treated as expired: a call made with one that
  # dies in flight fails for a reason nobody can act on.
  @margin_seconds 30

  @doc "Reads a token endpoint's answer."
  @spec from_response(map()) :: {:ok, t()} | {:error, term()}
  def from_response(%{"access_token" => access_token} = body) when is_binary(access_token) do
    {:ok,
     %__MODULE__{
       access_token: access_token,
       refresh_token: body["refresh_token"],
       expires_at: expires_at(body["expires_in"]),
       scope: body["scope"],
       type: body["token_type"] || "Bearer"
     }}
  end

  def from_response(%{"error" => error} = body) when is_binary(error),
    do: {:error, {:token_refused, error, description(body["error_description"])}}

  def from_response(_body), do: {:error, :token_unreadable}

  @doc """
  What an OAuth error answer says, as `{error, description}`: the error code,
  and the first 200 characters of its description where it has one. Nothing
  else the server sent is kept.
  """
  @spec refusal(term()) :: {String.t() | nil, String.t() | nil}
  def refusal(%{"error" => error} = body) when is_binary(error),
    do: {error, description(body["error_description"])}

  def refusal(_body), do: {nil, nil}

  defp description(text) when is_binary(text), do: String.slice(text, 0, 200)
  defp description(_absent), do: nil

  @doc """
  Writes down where `token` came from: the issuer and token endpoint of
  `metadata`, the client `registered` presented, and the resource.
  """
  @spec bind(t(), TarsOAuth.Metadata.t(), map()) :: t()
  def bind(%__MODULE__{} = token, metadata, registered) do
    %{
      token
      | issuer: metadata.issuer,
        token_endpoint: metadata.token_endpoint,
        client_id: registered.client_id,
        resource: metadata.resource
    }
  end

  @doc "Whether `token` knows where to be renewed."
  @spec bound?(t()) :: boolean()
  def bound?(%__MODULE__{} = token),
    do: is_binary(token.issuer) and is_binary(token.token_endpoint) and is_binary(token.client_id)

  @doc "Whether this token can still be used."
  @spec fresh?(t(), integer()) :: boolean()
  def fresh?(%__MODULE__{expires_at: nil}, _now), do: true
  def fresh?(%__MODULE__{expires_at: at}, now), do: at - @margin_seconds > now

  @doc "Whether this token can be renewed without the user: it has a refresh token and knows where to use it."
  @spec renewable?(t()) :: boolean()
  def renewable?(%__MODULE__{refresh_token: refresh} = token),
    do: is_binary(refresh) and bound?(token)

  @doc "The same token, no longer fresh, so the next use renews it."
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = token), do: %{token | expires_at: System.system_time(:second)}

  @doc """
  Reads a refreshed token, keeping the refresh token where a server sent none.

  An authorization server is allowed to answer a refresh with an access token
  alone, and dropping the old refresh token would log the user out.
  """
  @spec renewed(t(), t()) :: t()
  def renewed(%__MODULE__{} = previous, %__MODULE__{} = fresh) do
    %{
      struct(fresh, Map.take(previous, @bound))
      | refresh_token: fresh.refresh_token || previous.refresh_token
    }
  end

  @doc "Writes the token down as JSON."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = token), do: token |> Map.from_struct() |> JSON.encode!()

  @doc "Reads back what `encode/1` wrote."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    case JSON.decode(encoded) do
      {:ok, %{"access_token" => access_token} = fields} when is_binary(access_token) ->
        {:ok,
         %__MODULE__{
           access_token: access_token,
           refresh_token: fields["refresh_token"],
           expires_at: fields["expires_at"],
           scope: fields["scope"],
           issuer: fields["issuer"],
           token_endpoint: fields["token_endpoint"],
           client_id: fields["client_id"],
           resource: fields["resource"],
           type: fields["type"] || "Bearer"
         }}

      _unreadable ->
        {:error, :token_unreadable}
    end
  end

  defp expires_at(nil), do: nil
  defp expires_at(seconds) when is_integer(seconds), do: System.system_time(:second) + seconds

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {parsed, _rest} -> expires_at(parsed)
      :error -> nil
    end
  end

  defp expires_at(_other), do: nil

  defimpl Inspect do
    def inspect(%TarsOAuth.Token{} = token, _opts) do
      Inspect.Algebra.concat([
        "#TarsOAuth.Token<",
        token.scope || "no scope",
        ", ",
        expiry(token.expires_at),
        ", redacted>"
      ])
    end

    defp expiry(nil), do: "no expiry"
    defp expiry(at), do: "expires in #{at - System.system_time(:second)}s"
  end
end
