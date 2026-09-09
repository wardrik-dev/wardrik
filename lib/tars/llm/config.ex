defmodule Tars.LLM.Config do
  @moduledoc """
  Everything a turn needs that is not the conversation: who it is running for,
  which model, and which tools are available.

  This is wiring, not data. It is set when an agent starts and stays constant
  for the life of a turn, which is why tools live here rather than alongside
  `ReqLLM.Context` — context is what you will eventually persist, and tool
  callbacks (which may be anonymous functions) are not serializable.

  `agent_id` rides along so `Tars.LLM.Turn` and `Tars.LLM.ToolRunner` can emit
  events without a subscriber pid being threaded through their signatures.
  `Tars.Agent` fills it in at start-up.
  """

  defstruct agent_id: nil,
            model_spec: {:zai_coding_plan, model: "glm-5-turbo"},
            tools: []

  @type t :: %__MODULE__{
          agent_id: Tars.Events.agent_id(),
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
  def test_tools() do
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
