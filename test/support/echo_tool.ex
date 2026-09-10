defmodule Tars.Test.EchoTool do
  @moduledoc "A `Tars.Tool` that hands its arguments straight back."

  @behaviour Tars.Tool

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "echo",
      description: "Echo the value back.",
      parameter_schema: [value: [type: :any, required: true, doc: "Anything"]],
      callback: {__MODULE__, :run}
    )
  end

  def run(params), do: {:ok, params}
end
