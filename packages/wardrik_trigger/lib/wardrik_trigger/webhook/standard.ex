defmodule WardrikTrigger.Webhook.Standard do
  @moduledoc """
  The `standard` scheme: a webhook signed as the Standard Webhooks spec
  says, which many services follow. `webhook-signature` lists `v1,`
  signatures, each the base64 HMAC-SHA256 of `webhook-id`, `webhook-timestamp`
  and the body, joined by dots, with the secret: the base64 after `whsec_`.

  Its delivery ID is `webhook-id`, and its event the `type` of a JSON body.
  A request whose timestamp is more than five minutes from now is refused,
  so one sent again by someone who saw it does not verify for long.
  """

  @behaviour WardrikTrigger.Webhook.Scheme

  alias WardrikTrigger.Webhook.Scheme

  @tolerance 300

  @impl Scheme
  def verify(headers, body, secret) do
    id = Scheme.header(headers, "webhook-id")
    timestamp = Scheme.header(headers, "webhook-timestamp")

    with :ok <- present(id, timestamp),
         :ok <- recent(timestamp),
         :ok <- signed(Scheme.header(headers, "webhook-signature"), id, timestamp, body, secret) do
      {:ok, %{id: id, event: event(body)}}
    end
  end

  defp present(id, timestamp) when is_binary(id) and id != "" and is_binary(timestamp), do: :ok

  defp present(_id, _timestamp),
    do: {:error, "The request has no webhook-id and webhook-timestamp."}

  defp recent(timestamp) do
    case Integer.parse(timestamp) do
      {at, ""} ->
        if abs(System.system_time(:second) - at) <= @tolerance,
          do: :ok,
          else: {:error, "The request's webhook-timestamp is more than five minutes from now."}

      _unread ->
        {:error, "The request's webhook-timestamp is not a time."}
    end
  end

  defp signed(nil, _id, _timestamp, _body, _secret),
    do: {:error, "The request has no webhook-signature."}

  defp signed(signatures, id, timestamp, body, secret) do
    expected = secret |> key() |> Scheme.hmac("#{id}.#{timestamp}.#{body}")

    matched =
      for "v1," <> signature <- String.split(signatures, " ", trim: true),
          {:ok, given} <- [Base.decode64(signature)],
          Scheme.same?(given, expected),
          do: given

    if matched == [],
      do: {:error, "The request's signature does not match the webhook's secret."},
      else: :ok
  end

  defp key("whsec_" <> encoded), do: key(encoded)

  defp key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> key
      :error -> encoded
    end
  end

  defp event(body) do
    case JSON.decode(body) do
      {:ok, %{"type" => type}} when is_binary(type) -> type
      _other -> nil
    end
  end
end
