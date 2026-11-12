defmodule WardrikWeb.FormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias WardrikWeb.Form

  @define WardrikProtocol.operation("agent.define").input

  @definition %{
    "model" => "anthropic:claude-haiku-4-5",
    "instructions" => "Watch the queue.",
    "tools" => ["web_search", "linear/*"],
    "compaction" => false,
    "idle_timeout" => "infinity",
    "max_iterations" => 12,
    "retries" => %{"attempts" => 4, "on_exhausted" => "fail"},
    "model_options" => %{"temperature" => 0.2},
    "notify" => %{"on" => ["parked", "failed"], "to" => "ops"},
    "policy" => %{"ask" => ["linear/*"]},
    "triggers" => [
      %{"name" => "sweep", "every" => "*/30 * * * *", "prompt" => "Check the queue."},
      %{
        "name" => "hook",
        "prompt" => "An event.",
        "webhook" => %{"secret" => "${S}", "verify" => "shared"}
      }
    ]
  }

  test "a definition reads back as it was shown" do
    params = Form.params(@define, @definition)
    assert {:ok, @definition} == Form.read(@define, params)
  end

  test "every operation's input form renders and reads back empty" do
    for operation <- WardrikProtocol.operations() do
      html = render_component(&Form.fields/1, schema: operation.input, params: %{})
      assert is_binary(html)
      assert Form.read(operation.input, %{}) == :none
    end
  end

  test "adds and removes groups, and says which field doesn't read" do
    params = Form.add(%{}, ["triggers"]) |> Form.add(["triggers"])
    assert Map.keys(params["triggers"]) == ["0", "1"]
    assert Form.remove(params, ["triggers", "0"])["triggers"] |> Map.keys() == ["1"]

    assert {:error, "timeout doesn't read as a whole number."} =
             Form.read(@define, %{"timeout" => "soon"})

    assert {:error, "policy doesn't read as JSON."} =
             Form.read(@define, %{"policy" => %{"__variant" => "1", "value" => "{"}})
  end

  test "picks the union alternative a value fits" do
    schema = %{
      "oneOf" => [
        %{"const" => "all"},
        %{"enum" => ["a", "b"]},
        %{"type" => ["integer", "null"]},
        %{"type" => "number"},
        %{"type" => "boolean"},
        %{"type" => "array"},
        %{"type" => "object"},
        %{"type" => "string"},
        %{"title" => "anything"}
      ]
    }

    for {value, index} <- [
          {"all", 0},
          {"b", 1},
          {3, 2},
          {1.5, 3},
          {true, 4},
          {[1], 5},
          {%{}, 6},
          {"text", 7}
        ],
        do: assert(WardrikWeb.Form.params(schema, value)["__variant"] == Integer.to_string(index))
  end

  test "reads switches, checks and numbers, and says when a number doesn't read" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "on" => %{"type" => "boolean"},
        "picks" => %{"type" => "array", "items" => %{"enum" => ["a", "b"]}},
        "ratio" => %{"type" => "number"},
        "any" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      }
    }

    assert {:ok, %{"on" => true, "picks" => ["a"], "ratio" => 2}} =
             WardrikWeb.Form.read(schema, %{"on" => "true", "picks" => ["", "a"], "ratio" => "2"})

    assert {:ok, %{"ratio" => 0.5}} = WardrikWeb.Form.read(schema, %{"ratio" => "0.5"})

    assert {:error, "ratio doesn't read as a number."} =
             WardrikWeb.Form.read(schema, %{"ratio" => "x"})

    assert WardrikWeb.Form.kind(schema["properties"]["any"]) == :union
    assert WardrikWeb.Form.handle("other", %{}, %{}) == nil

    html =
      Phoenix.LiveViewTest.render_component(&WardrikWeb.Form.fields/1,
        schema: schema,
        params: %{"picks" => ["a"], "any" => %{"__variant" => "0", "value" => "x"}}
      )

    assert html =~ ~s(name="input[picks][]")
    assert html =~ ~s(name="input[any][value]")
  end
end
