defmodule Wardrik.Triggers.WebhookTest do
  use ExUnit.Case, async: true

  alias Wardrik.Triggers.Webhook

  @now ~U[2026-10-22 09:00:00Z]

  defp request(headers, body \\ "{}", path_secret \\ nil),
    do: %{headers: headers, body: body, path_secret: path_secret}

  defp signed(id, at, body) do
    mac = :crypto.mac(:hmac, :sha256, "key", "#{id}.#{at}.#{body}")
    signature = Base.encode64(mac)

    %{
      "webhook-id" => id,
      "webhook-timestamp" => "#{at}",
      "webhook-signature" => "v0,x v1,#{signature}"
    }
  end

  test "takes the shared secret as a bearer token, or at the end of the path" do
    shared = [verify: :shared, secret: "s3cret", now: @now]

    request = request(%{"authorization" => "Bearer s3cret"})
    assert :ok = Webhook.verify(request, shared)

    request = request(%{}, "{}", "s3cret")
    assert :ok = Webhook.verify(request, shared)

    request = request(%{"authorization" => "Bearer nope"})
    assert {:error, "it doesn't present the secret"} = Webhook.verify(request, shared)

    request = request(%{})
    assert {:error, _why} = Webhook.verify(request, shared)
  end

  test "checks a Standard Webhooks signature, and how old it is" do
    secret = "whsec_" <> Base.encode64("key")
    at = DateTime.to_unix(@now)
    standard = [verify: :standard, secret: secret, now: @now]

    fresh = signed("msg_1", at, "{}")
    stale = signed("msg_1", at - 600, "{}")

    request = request(fresh)
    assert :ok = Webhook.verify(request, standard)

    request = request(fresh, "{\"x\":1}")
    assert {:error, "its signature doesn't match"} = Webhook.verify(request, standard)

    request = request(stale)
    assert {:error, "it was signed too long ago"} = Webhook.verify(request, standard)

    request = request(%{})
    assert {:error, "it has no webhook-id header"} = Webhook.verify(request, standard)

    headers = %{signed("msg_1", at, "{}") | "webhook-timestamp" => "soon"}

    request = request(headers)
    assert {:error, "its webhook-timestamp isn't a time"} = Webhook.verify(request, standard)
  end

  test "names a request by its idempotency key, its webhook id, or its body" do
    request = request(%{"idempotency-key" => "k", "webhook-id" => "w"})
    assert Webhook.id(request) == "k"
    request = request(%{"webhook-id" => "w"})
    assert Webhook.id(request) == "w"

    request = request(%{}, "{}")

    hash = :crypto.hash(:sha256, "{}")
    assert Webhook.id(request) == Base.encode16(hash, case: :lower)
  end

  test "writes the body under the prompt, its first 32,768 characters" do
    prompt = Webhook.prompt("Triage it.", request(%{}, String.duplicate("a", 40_000)))
    assert String.length(prompt) == String.length("Triage it.\n\n") + 32_768
  end
end
