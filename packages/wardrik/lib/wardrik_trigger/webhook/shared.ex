defmodule WardrikTrigger.Webhook.Shared do
  @moduledoc """
  The `shared` verifier, a webhook trigger's default: the request presents
  the trigger's secret itself, as `Authorization: Bearer SECRET`, which any
  sender that sets a header can do. A sender that only lets you set a URL
  puts the secret at the end of the trigger's path instead, which the route
  hands on as the same header.

  Its delivery ID is the request's `Idempotency-Key` where it sends one, and
  otherwise the SHA-256 of its body, so a sender trying the same body again
  is asked about once.

  The secret proves who sent the request, and TLS keeps it whole on the way;
  it does not sign the body, as `standard` does, so a sender that can sign
  is better checked that way.
  """

  @behaviour WardrikTrigger.Webhook.Verifier

  alias WardrikTrigger.Webhook.Verifier

  @impl Verifier
  def verify(headers, body, secret) do
    with {:ok, presented} <- presented(Verifier.header(headers, "authorization")) do
      if Verifier.same?(presented, secret),
        do: {:ok, %{id: id(headers, body), event: nil}},
        else: {:error, "The request's secret is not the trigger's."}
    end
  end

  defp presented("Bearer " <> secret), do: {:ok, secret}
  defp presented(_other), do: {:error, "The request presents no secret."}

  defp id(headers, body) do
    case Verifier.header(headers, "idempotency-key") do
      key when is_binary(key) and key != "" -> key
      _none -> :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    end
  end
end
