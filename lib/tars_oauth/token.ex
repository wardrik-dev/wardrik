defmodule TarsOAuth.Token do
  @moduledoc """
  What an authorization server handed back, and when it stops being useful.

  Written to `TarsVault` as JSON and read back the same way, so a token
  survives a restart sealed rather than in the clear. `inspect/1` shows the
  scope and the expiry, never the token.
  """

  @enforce_keys [:access_token]
  defstruct [:access_token, :refresh_token, :expires_at, :scope, type: "Bearer"]

  @typedoc "An access token, and whatever came with it."
  @type t() :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: integer() | nil,
          scope: String.t() | nil,
          type: String.t()
        }

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

  def from_response(%{"error" => error} = body),
    do: {:error, {:token_refused, error, body["error_description"]}}

  def from_response(body), do: {:error, {:token_unreadable, body}}

  @doc "Whether this token can still be used."
  @spec fresh?(t(), integer()) :: boolean()
  def fresh?(%__MODULE__{expires_at: nil}, _now), do: true
  def fresh?(%__MODULE__{expires_at: at}, now), do: at - @margin_seconds > now

  @doc "Whether this token can be renewed without the user."
  @spec renewable?(t()) :: boolean()
  def renewable?(%__MODULE__{refresh_token: refresh}), do: is_binary(refresh)

  @doc """
  Reads a refreshed token, keeping the refresh token where a server sent none.

  An authorization server is allowed to answer a refresh with an access token
  alone, and dropping the old refresh token would log the user out.
  """
  @spec renewed(t(), t()) :: t()
  def renewed(%__MODULE__{} = previous, %__MODULE__{} = fresh) do
    %{fresh | refresh_token: fresh.refresh_token || previous.refresh_token}
  end

  @doc "Writes the token down as JSON."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = token), do: token |> Map.from_struct() |> JSON.encode!()

  @doc "Reads back what `encode/1` wrote."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    case JSON.decode(encoded) do
      {:ok, %{"access_token" => access_token} = fields} ->
        {:ok,
         %__MODULE__{
           access_token: access_token,
           refresh_token: fields["refresh_token"],
           expires_at: fields["expires_at"],
           scope: fields["scope"],
           type: fields["type"] || "Bearer"
         }}

      {:ok, other} ->
        {:error, {:token_unreadable, other}}

      {:error, reason} ->
        {:error, reason}
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
