defmodule Wardrik.Operations.RunningTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Wardrik

  alias Wardrik.Operations.Running

  setup :set_mimic_global
  setup :start_wardrik

  test "takes an agent another node started first as started", %{wardrik: wardrik} do
    elsewhere = start_agent(wardrik, "acme/elsewhere")

    stub(WardrikCore, :start_agent, fn _agents, _opts ->
      {:error, {:already_started, elsewhere}}
    end)

    assert {:ok, ^elsewhere} =
             Running.bring(wardrik,
               agent_id: "acme/raced",
               model: "anthropic:claude-haiku-4-5",
               capabilities: [Wardrik.Test.Tools]
             )
  end
end
