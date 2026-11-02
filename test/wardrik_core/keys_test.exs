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
    def fetch(%{name: name, principal: %Principal{id: owner}}, held),
      do: Map.fetch(held, {owner, name})
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
    assert Keys.fetch(context, "OTHER") == :error
    assert Keys.fetch(%{context | keys: nil}, "BRAVE_API_KEY") == :error
  end

  test "gives a model call its provider's key, and leaves ReqLLM to find one where none is held" do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert opts[:api_key] == "sk-acme"
      {:ok, answer("Hi.")}
    end)

    assert {:ok, _called} =
             WardrikCore.generate(context(%{{"acme", "ANTHROPIC_API_KEY"} => "sk-acme"}))

    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert opts == [tools: []]
      {:ok, answer("Hi.")}
    end)

    assert {:ok, _called} = WardrikCore.generate(context(%{}))
  end

  test "gives an evaluation its model's key" do
    expect(ReqLLM, :evaluate, fn "anthropic:claude-haiku-4-5", "state", %{}, opts ->
      assert opts == [api_key: "sk-acme"]
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
