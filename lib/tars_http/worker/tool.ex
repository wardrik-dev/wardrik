defmodule TarsHTTP.Worker.Tool do
  @moduledoc """
  One tool a worker offers, as its `tools/list` answer describes it in MCP's
  shape: a name, a description, and the JSON Schema its arguments follow.

  `in_doubt` is `:rerun` where the worker marks the tool with either of MCP's
  annotations `readOnlyHint` or `idempotentHint`, and `:ask` otherwise; see
  `c:Tars.Tool.in_doubt/1`.
  """

  @enforce_keys [:name, :input_schema]
  defstruct [:name, :description, :input_schema, in_doubt: :ask]

  @type t() :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          in_doubt: :ask | :rerun
        }

  # With "workers__" in front, a name stays within the 64 characters a model
  # takes for a tool's name.
  @name ~r/^[A-Za-z0-9_-]{1,55}$/

  @doc "The tool a `tools/list` entry describes, or `:error` for a name a model cannot take."
  @spec listed(term()) :: {:ok, t()} | :error
  def listed(%{"name" => name} = listed) when is_binary(name) do
    if Regex.match?(@name, name) do
      {:ok,
       %__MODULE__{
         name: name,
         description: listed["description"] || listed["title"],
         input_schema: listed["inputSchema"] || %{"type" => "object", "properties" => %{}},
         in_doubt: in_doubt(listed["annotations"])
       }}
    else
      :error
    end
  end

  def listed(_other), do: :error

  defp in_doubt(%{"readOnlyHint" => true}), do: :rerun
  defp in_doubt(%{"idempotentHint" => true}), do: :rerun
  defp in_doubt(_annotations), do: :ask
end
