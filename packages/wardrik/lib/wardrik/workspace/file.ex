defmodule Wardrik.Workspace.File do
  @moduledoc """
  A file in a workspace.

    * `:content` - the file's text.
    * `:by` - the agent that last wrote it.
    * `:at` - when it was last written.
    * `:labels` - labels of what the writing run had read, such as `"outside"`.
  """

  @enforce_keys [:content]
  defstruct [:content, :by, :at, labels: []]

  @type t() :: %__MODULE__{
          content: String.t(),
          by: String.t() | nil,
          at: DateTime.t() | nil,
          labels: [String.t()]
        }

  @doc "Returns the file's labels, or `[]`."
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{} = file), do: Map.get(file, :labels, [])

  @doc """
  Wraps a tool's `answer` with the labels of `files`, as `{:ok, %ReqLLM.ToolResult{}}`. Returns
  `{:ok, answer}` when there are none.
  """
  @spec labelled(map(), [t()]) :: {:ok, map() | ReqLLM.ToolResult.t()}
  def labelled(answer, files) do
    case files |> Enum.flat_map(&labels/1) |> Enum.uniq() |> Enum.sort() do
      [] -> {:ok, answer}
      labels -> {:ok, %ReqLLM.ToolResult{output: answer, metadata: %{labels: labels}}}
    end
  end
end
