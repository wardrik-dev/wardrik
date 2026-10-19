defmodule Wardrik.Test.EchoTool do
  @moduledoc "A `Wardrik.Tool` that hands its arguments straight back."

  use Wardrik.Tool

  @impl true
  def tool do
    Wardrik.Tool.new!(
      name: "echo",
      description: "Echo the value back.",
      schema: [value: [type: :any, required: true, doc: "Anything"]],
      run: {__MODULE__, :run, []}
    )
  end

  def run(params, _context), do: {:ok, params}
end
