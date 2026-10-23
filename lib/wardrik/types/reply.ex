defmodule Wardrik.Reply do
  @moduledoc "An agent's answer to a message: its `text`, the `message` it answers, and the `run` that wrote it."

  @enforce_keys [:message, :run, :text]
  defstruct [:message, :run, :text]

  @type t() :: %__MODULE__{message: String.t(), run: String.t(), text: String.t()}
end
