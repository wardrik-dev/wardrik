defmodule WardrikCore.KeysTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Keys
  alias WardrikCore.Principal

  defmodule Held do
    @behaviour WardrikCore.Keys

    @impl true
    def fetch(%{name: name, principal: %Principal{id: owner}}, held) do
      case Map.fetch(held, {owner, name}) do
        {:ok, key} -> {:ok, key}
        :error -> {:error, :not_found}
      end
    end
  end

  defp context(held),
    do:
      Context.new(
        model: "anthropic:claude-haiku-4-5",
        messages: [ReqLLM.Context.user("hi")],
        principal: %Principal{id: "acme"},
        keys: {Held, held}
      )

  test "names the key a model's provider takes" do
    assert Keys.key_name("anthropic:claude-haiku-4-5") == "ANTHROPIC_API_KEY"
    assert Keys.key_name("zai_coding_plan:glm-5.1") == "ZAI_API_KEY"
    assert Keys.key_name("no_such_provider_here:x") == nil
    assert Keys.key_name("unnamed") == nil
  end

  test "fetches a key for whoever the agent works for" do
    context = context(%{{"acme", "BRAVE_API_KEY"} => "brave-acme"})

    assert Keys.fetch(context, "BRAVE_API_KEY") == {:ok, "brave-acme"}
    assert Keys.fetch(context, "OTHER") == {:error, :not_found}
    assert Keys.fetch(%{context | keys: nil}, "BRAVE_API_KEY") == {:error, :not_found}
  end

  test "gives a model call its provider's key, and leaves ReqLLM to find one where none is held" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert opts[:api_key] == "sk-acme"
      {:ok, answer("Hi.")}
    end)

    with_key = context(%{{"acme", "ANTHROPIC_API_KEY"} => "sk-acme"})
    assert {:ok, _called} = WardrikCore.generate(with_key)

    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      refute Keyword.has_key?(opts, :api_key)
      assert opts[:receive_timeout] == 300_000
      assert opts[:stream_idle_timeout] == 300_000
      {:ok, answer("Hi.")}
    end)

    without_key = context(%{})
    assert {:ok, _called} = WardrikCore.generate(without_key)
  end

  test "calls an endpoint's model at its base_url, with only the key it names" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    expect(ReqLLM, :stream_text, fn "openai:gpt-4o-mini", _messages, opts ->
      assert opts[:base_url] == "http://localhost:9931/v1"
      assert opts[:api_key] == "local-key"
      {:ok, answer("Hi.")}
    end)

    held = %{{"acme", "OPENAI_API_KEY"} => "sk-openai", {"acme", "LOCAL_KEY"} => "local-key"}

    endpoint = [
      model: "openai:gpt-4o-mini",
      base_url: "http://localhost:9931/v1",
      key: "LOCAL_KEY"
    ]

    context = %{context(held) | model: "local", endpoints: %{"local" => endpoint}}

    assert {:ok, _called} = WardrikCore.generate(context)
  end

  test "never gives an endpoint its provider's key" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    expect(ReqLLM, :stream_text, fn "openai:gpt-4o-mini", _messages, opts ->
      assert opts[:api_key] == "none"
      {:ok, answer("Hi.")}
    end)

    endpoint = [model: "openai:gpt-4o-mini", base_url: "http://localhost:9931/v1"]
    held = %{{"acme", "OPENAI_API_KEY"} => "sk-openai"}
    context = %{context(held) | model: "local", endpoints: %{"local" => endpoint}}

    assert {:ok, _called} = WardrikCore.generate(context)
  end

  test "gives a model call the agent's model_options over the defaults" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert opts[:receive_timeout] == 1_000
      assert opts[:stream_idle_timeout] == 300_000
      assert opts[:temperature] == 0.2
      {:ok, answer("Hi.")}
    end)

    context = %{context(%{}) | model_options: [receive_timeout: 1_000, temperature: 0.2]}
    assert {:ok, _called} = WardrikCore.generate(context)
  end

  test "gives an evaluation its model's key" do
    expect(ReqLLM, :evaluate, fn "anthropic:claude-haiku-4-5", "state", %{}, opts ->
      assert opts[:api_key] == "sk-acme"
      {:ok, %ReqLLM.Response{id: "e", model: "m", context: nil, object: %{}}}
    end)

    context = context(%{{"acme", "ANTHROPIC_API_KEY"} => "sk-acme"})

    assert {:ok, %{}, _measured} =
             WardrikCore.evaluate(context,
               model: "anthropic:claude-haiku-4-5",
               state: "state",
               questions: %{}
             )
  end
end
