defmodule Tars.LLM.RequestTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.LLM.Config
  alias Tars.LLM.Request
  alias Tars.Test.EchoTool

  test "new/2 carries the model, the conversation and the generation options" do
    config = Config.new(generation: [max_tokens: 100], model_spec: {:anthropic, model: "x"})
    context = Context.new([Context.user("hi")])

    request = Request.new(config, context)

    assert request.model_spec == {:anthropic, model: "x"}
    assert request.context == context
    assert request.opts[:max_tokens] == 100
  end

  test "new/2 takes tools and persona from their own fields, not from generation" do
    config =
      Config.new(
        tools: [EchoTool],
        system: "Be brief.",
        generation: [tools: [], system_prompt: "ignored"]
      )

    request = Request.new(config, Context.new())

    assert Enum.map(request.opts[:tools], & &1.name) == ["echo"]
    assert request.opts[:system_prompt] == "Be brief."
  end

  test "new/2 leaves out the persona entirely when a config has none" do
    request = Request.new(Config.new(), Context.new())

    refute Keyword.has_key?(request.opts, :system_prompt)
  end

  test "put_opts/2 merges over what is already there" do
    request = Config.new(generation: [max_tokens: 100]) |> Request.new(Context.new())

    updated = Request.put_opts(request, api_key: "secret", max_tokens: 50)

    assert updated.opts[:api_key] == "secret"
    assert updated.opts[:max_tokens] == 50
  end

  test "put_model/2 sends the same conversation to a different model" do
    request = Request.new(Config.new(), Context.new([Context.user("hi")]))

    updated = Request.put_model(request, {:openai, model: "gpt-5"})

    assert updated.model_spec == {:openai, model: "gpt-5"}
    assert updated.context == request.context
  end
end
