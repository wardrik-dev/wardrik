defmodule Wardrik.Workspace.File do
  @moduledoc """
  A file in a workspace.

    * `:content` - the file's text.
    * `:by` - the agent that last wrote it.
    * `:at` - when it was last written.
    * `:labels` - labels of what the writing run had read, such as `"outside"`.

  The store keeps it with `:at` in ISO 8601.
  """

  @behaviour Wardrik.Store.Format

  @enforce_keys [:content]
  defstruct [:content, :by, :at, labels: []]

  @type t() :: %__MODULE__{
          content: String.t(),
          by: String.t() | nil,
          at: DateTime.t() | nil,
          labels: [String.t()]
        }

  @impl Wardrik.Store.Format
  def version, do: 1

  @impl Wardrik.Store.Format
  def dump(%__MODULE__{} = file) do
    %{
      "content" => file.content,
      "by" => file.by,
      "at" => file.at && DateTime.to_iso8601(file.at),
      "labels" => labels(file)
    }
  end

  @impl Wardrik.Store.Format
  def load(1, %{"content" => content, "by" => by, "at" => at, "labels" => labels}) do
    with {:ok, at} <- at(at),
         do: {:ok, %__MODULE__{content: content, by: by, at: at, labels: labels}}
  end

  @doc "Returns the file's labels, or `[]`."
  @spec labels(t()) :: [String.t()]
  def labels(%__MODULE__{} = file), do: Map.get(file, :labels, [])

  @doc """
  Wraps a tool's `answer` with the labels of `files`, as `{:ok, %ReqLLM.ToolResult{}}`. Returns
  `{:ok, answer}` when there are none.
  """
  @spec labelled(map(), [t()]) :: {:ok, map() | ReqLLM.ToolResult.t()}
  def labelled(answer, files) do
    labels =
      files
      |> Enum.flat_map(&labels/1)
      |> Enum.uniq()
      |> Enum.sort()

    case labels do
      [] -> {:ok, answer}
      labels -> {:ok, %ReqLLM.ToolResult{output: answer, metadata: %{labels: labels}}}
    end
  end

  defp at(nil), do: {:ok, nil}

  defp at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, reason} -> {:error, "its time #{at} isn't ISO 8601: #{reason}"}
    end
  end
end
