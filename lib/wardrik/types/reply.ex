defmodule Wardrik.Reply do
  @moduledoc "An agent's answer to a message: its `text`, the `message` it answers, and the `run` that wrote it."

  @enforce_keys [:message, :run, :text]
  defstruct [:message, :run, :text]

  @type t() :: %__MODULE__{message: String.t(), run: String.t(), text: String.t()}

  @doc "Returns what the assistant said in `messages`, as a `wardrik.run.completed` event's data holds them."
  @spec text([map()]) :: String.t()
  def text(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.flat_map(&Map.get(&1, "parts", []))
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join(& &1["content"])
  end
end
