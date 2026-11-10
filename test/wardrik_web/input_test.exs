defmodule WardrikWeb.InputTest do
  use ExUnit.Case, async: true

  alias WardrikWeb.Input

  test "reads every operation's form, leaving empty fields out" do
    for operation <- WardrikProtocol.operations() do
      fields = Input.fields(operation)
      assert {:ok, %{}} == Input.read(fields, %{})
      assert Enum.take_while(fields, & &1.required) == Enum.filter(fields, & &1.required)
    end
  end

  test "reads numbers, lines, switches and JSON" do
    fields = [
      %Input.Field{name: "limit", kind: :number},
      %Input.Field{name: "agents", kind: :lines},
      %Input.Field{name: "on", kind: :switch},
      %Input.Field{name: "data", kind: :json}
    ]

    assert {:ok, %{"limit" => 5, "agents" => ["a", "b"], "on" => true, "data" => %{"x" => 1}}} =
             Input.read(fields, %{
               "limit" => "5",
               "agents" => "a\n b \n",
               "on" => "true",
               "data" => ~s({"x": 1})
             })

    assert {:error, "data doesn't read as json."} = Input.read(fields, %{"data" => "{"})
    assert {:error, "limit doesn't read as number."} = Input.read(fields, %{"limit" => "five"})
  end

  test "paths encode each segment" do
    dashboard = %WardrikWeb.Dashboard{prefix: "/ops", resolver: {nil, nil}}

    assert WardrikWeb.path(dashboard, ["agents", "acme/triage"], %{"tab" => "runs", "x" => nil}) ==
             "/ops/agents/acme%2Ftriage?tab=runs"

    assert WardrikWeb.path(%{dashboard | prefix: "/"}, []) == "/"
  end
end
