defmodule WardrikTrigger.Webhook.GitHub do
  @moduledoc """
  The `github` scheme: a GitHub webhook, signed in `X-Hub-Signature-256` as
  the hex HMAC-SHA256 of its body with the webhook's secret. Its delivery ID
  is `X-GitHub-Delivery`, which GitHub sends again when a delivery is
  redelivered, and its event is `X-GitHub-Event`, such as `issues`.

  GitHub signs no time, so a request sent again by someone who saw it is
  told apart only by its delivery ID, which the trigger has seen.
  """

  @behaviour WardrikTrigger.Webhook.Scheme

  alias WardrikTrigger.Webhook.Scheme

  @impl Scheme
  def verify(headers, body, secret) do
    with {:ok, signature} <- signature(Scheme.header(headers, "x-hub-signature-256")),
         :ok <- matches(signature, Scheme.hmac(secret, body)),
         {:ok, id} <- delivery(Scheme.header(headers, "x-github-delivery")) do
      {:ok, %{id: id, event: Scheme.header(headers, "x-github-event")}}
    end
  end

  defp signature("sha256=" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, signature} -> {:ok, signature}
      :error -> unsigned()
    end
  end

  defp signature(_other), do: unsigned()

  defp unsigned, do: {:error, "The request has no X-Hub-Signature-256 that reads."}

  defp matches(signature, expected) do
    if Scheme.same?(signature, expected),
      do: :ok,
      else: {:error, "The request's signature does not match the webhook's secret."}
  end

  defp delivery(id) when is_binary(id) and id != "", do: {:ok, id}
  defp delivery(_none), do: {:error, "The request has no X-GitHub-Delivery."}
end
