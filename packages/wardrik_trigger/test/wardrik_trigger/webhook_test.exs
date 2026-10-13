defmodule WardrikTrigger.WebhookTest do
  use ExUnit.Case, async: true

  alias WardrikTrigger.Item
  alias WardrikTrigger.Webhook
  alias WardrikTrigger.Webhook.Shared
  alias WardrikTrigger.Webhook.Standard

  @agent Wardrik.AgentID.parse!("acme/hooked")

  defp hook(secret),
    do: Webhook.new("issues", verify: "standard", secret: secret, prompt: "Look.")

  describe "decode/2" do
    test "reads a webhook trigger from its own settings, and writes it back" do
      fields = %{"webhook" => %{"secret" => "${HOOK_SECRET}"}, "prompt" => "Look."}

      assert {:ok,
              %Webhook{
                name: "issues",
                secret: "HOOK_SECRET",
                verify: "shared",
                prompt: "Look.",
                overlap: :queue
              } = hook} = Webhook.decode("issues", fields)

      assert WardrikTrigger.encode(hook) == %{
               "name" => "issues",
               "webhook" => %{"secret" => "${HOOK_SECRET}", "verify" => "shared"},
               "prompt" => "Look.",
               "overlap" => "queue"
             }

      assert {:ok, %Webhook{verify: "standard", overlap: :skip}} =
               Webhook.decode(
                 "issues",
                 %{
                   fields
                   | "webhook" => %{"secret" => "${HOOK_SECRET}", "verify" => "standard"}
                 }
                 |> Map.put("overlap", "skip")
               )
    end

    test "says what does not read" do
      base = %{"webhook" => %{"secret" => "${S}"}, "prompt" => "Look."}

      for {fields, message} <- [
            {%{base | "webhook" => %{"secret" => "${S}", "verify" => "gitlab"}},
             "verify is one of shared, standard"},
            {%{base | "webhook" => %{}}, "a webhook has a secret, as ${NAME}"},
            {%{base | "webhook" => %{"secret" => "hunter2"}},
             "a webhook has a secret, as ${NAME}"},
            {%{base | "webhook" => %{"secret" => "${S}", "url" => "x"}},
             "url is not a setting of webhook"},
            {%{base | "webhook" => "yes"},
             "webhook holds its secret, and how a request is verified"},
            {Map.delete(base, "prompt"), "prompt is a string, got nil"},
            {Map.put(base, "overlap", "now"), "overlap is one of skip, queue"},
            {Map.put(base, "every", "1h"),
             "every is not a setting of a webhook trigger, which asks as each request arrives"}
          ] do
        assert Webhook.decode("issues", fields) == {:error, message}
      end
    end

    test "says where a service sends requests, by the agent's ID" do
      assert Webhook.path(Wardrik.AgentID.parse!("acme/@jon/triage"), "issues") ==
               "/v1/hooks/acme/@jon/triage/issues"
    end
  end

  describe "received/3" do
    test "reads the secret for the trigger's agent, so each org has its own" do
      body = ~s({"type":"invoice.paid"})
      opts = hook("WARDRIK_TEST_VAULTED")

      assert {:ok, %Item{id: "msg_1", title: "invoice.paid", text: ^body, labels: ["outside"]}} =
               Webhook.received(opts, standard("msg_1", now(), body, "acme's"), @agent)

      globex = Wardrik.AgentID.parse!("globex/hooked")

      assert {:error, :forbidden, _message} =
               Webhook.received(opts, standard("msg_1", now(), body, "acme's"), globex)

      assert {:ok, %Item{}} =
               Webhook.received(opts, standard("msg_1", now(), body, "globex's"), globex)
    end

    test "is unavailable where the secret is not set" do
      assert {:error, :unavailable, _message} =
               Webhook.received(
                 hook("WARDRIK_TEST_UNSET"),
                 standard("msg_1", now(), "{}", "x"),
                 @agent
               )
    end

    test "shows the first of a long body, and none that is not text" do
      opts = hook("WARDRIK_TEST_VAULTED")
      long = String.duplicate("a", 40_000)

      assert {:ok, %Item{text: text}} =
               Webhook.received(opts, standard("m", now(), long, "acme's"), @agent)

      assert String.length(text) == 32_769

      assert {:ok, %Item{text: "(2 bytes that are not text)"}} =
               Webhook.received(opts, standard("m", now(), <<255, 0>>, "acme's"), @agent)
    end
  end

  describe "Shared" do
    test "takes the secret the request presents, and dedupes by its key or its body" do
      bearer = {"authorization", "Bearer s3cret"}
      digest = :sha256 |> :crypto.hash("{}") |> Base.encode16(case: :lower)

      assert Shared.verify([bearer], "{}", "s3cret") == {:ok, %{id: digest, event: nil}}

      assert Shared.verify([bearer, {"idempotency-key", "k-1"}], "{}", "s3cret") ==
               {:ok, %{id: "k-1", event: nil}}
    end

    test "refuses a request with no secret, or another" do
      assert Shared.verify([], "{}", "s3cret") == {:error, "The request presents no secret."}

      assert Shared.verify([{"authorization", "Bearer guess"}], "{}", "s3cret") ==
               {:error, "The request's secret is not the trigger's."}
    end
  end

  describe "Standard" do
    test "verifies a signature among those listed, with a whsec_ secret" do
      key = "whsec_" <> Base.encode64("k3y")
      %{headers: headers} = standard("msg_1", now(), ~s({"type":"user.created"}), key)
      {"webhook-signature", signature} = List.keyfind(headers, "webhook-signature", 0)

      headers =
        List.keyreplace(
          headers,
          "webhook-signature",
          0,
          {"webhook-signature", "v1,AAAA " <> signature}
        )

      assert Standard.verify(headers, ~s({"type":"user.created"}), key) ==
               {:ok, %{id: "msg_1", event: "user.created"}}
    end

    test "refuses a request with no matching signature, or too old" do
      %{headers: headers} = standard("msg_1", now(), "{}", "k")

      assert {:error, "The request's signature does not match" <> _} =
               Standard.verify(headers, "{}", "j")

      %{headers: headers} = standard("msg_1", now() - 600, "{}", "k")

      assert {:error, "The request's webhook-timestamp is more than" <> _} =
               Standard.verify(headers, "{}", "k")

      %{headers: headers} = standard("msg_1", "soon", "{}", "k")

      assert {:error, "The request's webhook-timestamp is not a time."} =
               Standard.verify(headers, "{}", "k")

      assert {:error, "The request has no webhook-id" <> _} = Standard.verify([], "{}", "k")

      headers = [{"webhook-id", "msg_1"}, {"webhook-timestamp", to_string(now())}]

      assert {:error, "The request has no webhook-signature."} =
               Standard.verify(headers, "{}", "k")
    end
  end

  defp now, do: System.system_time(:second)

  defp standard(id, timestamp, body, secret) do
    key =
      case secret do
        "whsec_" <> encoded -> Base.decode64!(encoded)
        raw -> raw
      end

    signature =
      :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}") |> Base.encode64()

    %{
      headers: [
        {"webhook-id", id},
        {"webhook-timestamp", to_string(timestamp)},
        {"webhook-signature", "v1," <> signature}
      ],
      body: body
    }
  end
end
