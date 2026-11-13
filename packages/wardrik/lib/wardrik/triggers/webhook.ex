defmodule Wardrik.Triggers.Webhook do
  @moduledoc """
  Verifies webhook requests against a trigger's secret.

      :ok =
        Wardrik.Triggers.Webhook.verify(request,
          verify: :shared,
          secret: "s3cret",
          now: DateTime.utc_now()
        )

    * `:shared` - the request sends `Authorization: Bearer SECRET`, or `:path_secret`.
    * `:standard` - the request is signed as [Standard Webhooks](https://www.standardwebhooks.com/)
      specifies. A signature over five minutes old fails.
  """

  @tolerance 300
  @body 32_768

  @typedoc "A request: its raw `body`, its `headers` with lowercase names, and an optional `path_secret`."
  @type request() :: %{
          required(:body) => String.t(),
          required(:headers) => %{String.t() => String.t()},
          optional(:path_secret) => String.t() | nil
        }

  @doc "Returns `:ok` if `request` verifies against `:secret`, or `{:error, reason}`."
  @spec verify(request(), verify: :shared | :standard, secret: String.t(), now: DateTime.t()) ::
          :ok | {:error, String.t()}
  def verify(request, args) do
    verified(
      Keyword.fetch!(args, :verify),
      Keyword.fetch!(args, :secret),
      request,
      Keyword.fetch!(args, :now)
    )
  end

  defp verified(:shared, secret, request, _now) do
    presented = bearer(request.headers["authorization"]) || Map.get(request, :path_secret)

    if same?(presented, secret),
      do: :ok,
      else: {:error, "it doesn't present the secret"}
  end

  defp verified(:standard, secret, %{headers: headers, body: body}, now) do
    with {:ok, id} <- header(headers, "webhook-id"),
         {:ok, timestamp} <- header(headers, "webhook-timestamp"),
         {:ok, signatures} <- header(headers, "webhook-signature"),
         :ok <- recent(timestamp, now) do
      expected = signature(secret, "#{id}.#{timestamp}.#{body}")

      if Enum.any?(String.split(signatures, " "), &same?(&1, "v1," <> expected)),
        do: :ok,
        else: {:error, "its signature doesn't match"}
    end
  end

  @doc "Returns the request's id: its `Idempotency-Key`, its `webhook-id`, or a SHA-256 of its body."
  @spec id(request()) :: String.t()
  def id(%{headers: headers, body: body}) do
    headers["idempotency-key"] || headers["webhook-id"] ||
      Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  @doc "Appends the first #{@body} characters of the request's body to `prompt`."
  @spec prompt(String.t(), request()) :: String.t()
  def prompt(prompt, %{body: body}), do: prompt <> "\n\n" <> String.slice(body, 0, @body)

  defp bearer("Bearer " <> token), do: token
  defp bearer(_header), do: nil

  defp header(headers, name) do
    case Map.fetch(headers, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "it has no #{name} header"}
    end
  end

  defp recent(timestamp, now) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        if abs(DateTime.to_unix(now) - seconds) <= @tolerance,
          do: :ok,
          else: {:error, "it was signed too long ago"}

      _not_a_time ->
        {:error, "its webhook-timestamp isn't a time"}
    end
  end

  defp signature("whsec_" <> key, content), do: signature(Base.decode64!(key), content)

  defp signature(key, content) do
    :hmac
    |> :crypto.mac(:sha256, key, content)
    |> Base.encode64()
  end

  defp same?(presented, expected)
       when is_binary(presented) and byte_size(presented) == byte_size(expected),
       do: :crypto.hash_equals(presented, expected)

  defp same?(_presented, _expected), do: false
end
