defmodule Tars.LLM.Config do
  @moduledoc """
  What a caller supplies to an agent: which model to run, and what it can call.

  Declarative and inert. Nothing here is assigned by the running system, so a
  config is the piece you can build once and reuse, hand to another agent, or
  read out of a file.

      config = Tars.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
      Tars.Agent.Supervisor.start(:assistant, config: config)

  The runtime wiring a turn also needs, such as who its events are published
  to, lives on `Tars.Scope`. Tool callbacks are the one part of a config that
  does not travel: prefer `{module, function}` over an anonymous function for
  any agent that may be started on another node.
  """

  defstruct model_spec: {:zai_coding_plan, model: "glm-5-turbo"},
            tools: []

  @type t :: %__MODULE__{
          model_spec: {atom(), keyword()},
          tools: list(ReqLLM.Tool.t())
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  @spec add_tool(t(), ReqLLM.Tool.t()) :: t()
  def add_tool(%__MODULE__{tools: tools} = config, %ReqLLM.Tool{} = tool) do
    %{config | tools: [tool | tools]}
  end

  # For testing, to be removed eventually
  def test_tools do
    {:ok, tool_1} =
      ReqLLM.Tool.new(
        name: "echo",
        description: "echo",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn i -> {:ok, i} end
      )

    {:ok, tool_2} =
      ReqLLM.Tool.new(
        name: "fail",
        description: "fail",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn _i -> {:error, "failed"} end
      )

    {:ok, tool_3} =
      ReqLLM.Tool.new(
        name: "crash",
        description: "crash",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn _i -> raise "crashed" end
      )

    [tool_1, tool_2, tool_3]
  end
end
