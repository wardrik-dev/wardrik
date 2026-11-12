defmodule WardrikCore.ContextTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Context

  defmodule Tag do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, next, _opts) do
      context = update_in(context.metadata[:trail], &[:tag | &1 || []])
      next.(context)
    end
  end

  defmodule Label do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, next, label) do
      next.(update_in(context.metadata[:trail], &[label | &1 || []]))
    end
  end

  defmodule Halt do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, _next, _opts), do: {:park, :needs_approval, context}
  end

  test "new/1 rejects options it doesn't know" do
    assert_raise KeyError, fn -> Context.new(not_a_field: true) end
  end

  describe "run/2" do
    test "runs middleware outermost first, then the function" do
      context = Context.new(middleware: [Tag, Tag])

      assert {:ok, %Context{metadata: %{trail: [:done, :tag, :tag]}}} =
               Context.run(context, fn ctx ->
                 {:ok, update_in(ctx.metadata[:trail], &[:done | &1])}
               end)
    end

    test "hands each {module, opts} entry its own options" do
      context = Context.new(middleware: [{Label, :outer}, {Label, :inner}])

      assert {:ok, %Context{metadata: %{trail: [:inner, :outer]}}} =
               Context.run(context, &{:ok, &1})
    end

    test "a middleware can stop the pipeline without calling next" do
      context = Context.new(middleware: [Halt])

      assert {:park, :needs_approval, ^context} =
               Context.run(context, fn _ -> flunk("next should not run") end)
    end
  end

  test "run/3 keeps chunk handlers to the step that added them" do
    handler = fn _chunk -> :ok end

    assert {:ok, %Context{on_chunk: [], step: nil}} =
             Context.run(Context.new([]), :generate, fn context ->
               {:ok, %{context | on_chunk: [handler | context.on_chunk]}}
             end)
  end

  test "tool/2 finds the tool a call names" do
    tool = WardrikCore.Tool.new!(name: "echo", description: "echo", run: fn _, _ -> {:ok, ""} end)
    context = Context.new(tools: [tool])

    assert ^tool = Context.tool(context, %WardrikCore.ToolCall{id: "1", name: "echo"})
    assert nil == Context.tool(context, %WardrikCore.ToolCall{id: "2", name: "nope"})
  end

  describe "acting_for/1" do
    setup do
      %{
        agent: %WardrikCore.Principal{id: "agent:triage"},
        maria: %WardrikCore.Principal{id: "user:maria"}
      }
    end

    test "is whoever sent the latest message", %{agent: agent, maria: maria} do
      messages = [
        ReqLLM.Context.user("earlier", %{}),
        ReqLLM.Context.user("now", %{principal: maria}),
        ReqLLM.Context.assistant("on it")
      ]

      assert ^maria = Context.acting_for(Context.new(principal: agent, messages: messages))
    end

    test "is the agent itself when no one signed the message", %{agent: agent, maria: maria} do
      messages = [
        ReqLLM.Context.user("earlier", %{principal: maria}),
        ReqLLM.Context.user("now", %{})
      ]

      assert ^agent = Context.acting_for(Context.new(principal: agent, messages: messages))
      assert nil == Context.acting_for(Context.new(messages: []))
    end
  end

  describe "labels/1" do
    test "is each label the messages hold, once, in order" do
      messages = [
        ReqLLM.Context.user("hi", %{labels: ["outside"]}),
        ReqLLM.Context.assistant("on it"),
        %{
          ReqLLM.Context.tool_result("1", "read", "x")
          | metadata: %{labels: ["books", "outside"]}
        }
      ]

      assert Context.labels(Context.new(messages: messages)) == ["books", "outside"]
      assert Context.labels(Context.new(messages: [ReqLLM.Context.user("hi")])) == []
      assert Context.labels(messages) == ["books", "outside"]
    end
  end
end
