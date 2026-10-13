defmodule WardrikTrigger.WebhookTest do
  use ExUnit.Case, async: true

  alias WardrikTrigger.Item
  alias WardrikTrigger.Webhook
  alias WardrikTrigger.Webhook.GitHub
  alias WardrikTrigger.Webhook.Standard

  @agent Wardrik.AgentID.parse!("acme/hooked")

  defp hook(secret),
    do: Webhook.new("issues", scheme: "standard", secret: secret, prompt: "Look.")

  describe "decode/2" do
    test "reads a webhook trigger, which queues by default, and writes it back" do
      fields = %{"webhook" => "standard", "secret" => "${HOOK_SECRET}", "prompt" => "Look."}

      assert {:ok,
              %Webhook{
                name: "issues",
                scheme: "standard",
                secret: "HOOK_SECRET",
                prompt: "Look.",
                overlap: :queue
              } = hook} = Webhook.decode("issues", fields)

      assert WardrikTrigger.encode(hook) ==
               Map.merge(fields, %{"name" => "issues", "overlap" => "queue"})

      assert {:ok, %Webhook{overlap: :skip}} =
               Webhook.decode("issues", Map.put(fields, "overlap", "skip"))
    end

    test "says what does not read" do
      base = %{"webhook" => "github", "secret" => "${S}", "prompt" => "Look."}

      for {fields, message} <- [
            {%{base | "webhook" => "gitlab"}, "webhook is one of github, standard"},
            {Map.delete(base, "secret"), "a webhook has a secret, as ${NAME}"},
            {%{base | "secret" => "hunter2"}, "a webhook has a secret, as ${NAME}"},
            {Map.delete(base, "prompt"), "prompt is a string, got nil"},
            {Map.put(base, "overlap", "now"), "overlap is one of skip, queue"},
            {Map.put(base, "every", "1h"),
             "every is not a setting of a webhook, which asks as each request arrives"}
          ] do
        assert Webhook.decode("issues", fields) == {:error, message}
      end
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

  describe "GitHub" do
    defp github_headers(body, secret, extra \\ []) do
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

      [
        {"x-github-delivery", "d-1"},
        {"x-github-event", "push"},
        {"x-hub-signature-256", "sha256=" <> signature}
      ] ++ extra
    end

    test "verifies the body's signature" do
      assert GitHub.verify(github_headers("{}", "s"), "{}", "s") ==
               {:ok, %{id: "d-1", event: "push"}}
    end

    test "refuses a request that is not signed, or not with the secret" do
      assert {:error, "The request's signature does not match" <> _} =
               GitHub.verify(github_headers("{}", "s"), "{}", "other")

      assert {:error, "The request's signature does not match" <> _} =
               GitHub.verify(github_headers("{}", "s"), "{\"x\":1}", "s")

      assert {:error, "The request has no X-Hub-Signature-256" <> _} =
               GitHub.verify([{"x-github-delivery", "d-1"}], "{}", "s")

      assert {:error, "The request has no X-Hub-Signature-256" <> _} =
               GitHub.verify([{"x-hub-signature-256", "sha256=zz"}], "{}", "s")

      headers = List.keydelete(github_headers("{}", "s"), "x-github-delivery", 0)
      assert {:error, "The request has no X-GitHub-Delivery."} = GitHub.verify(headers, "{}", "s")
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
