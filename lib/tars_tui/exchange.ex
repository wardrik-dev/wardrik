defmodule TarsTUI.Exchange do
  @moduledoc """
  One tool call of a conversation and what it returned, as `TarsTUI.App`
  keeps them for `/tools`.

  A call is recorded when the model makes it, with `output` and `ok?` still
  `nil`, and completed when its result arrives: by `id` when both sides carry
  one, otherwise the oldest call of that name still waiting.
  """

  @type t() :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          arguments: map(),
          output: String.t() | nil,
          ok?: boolean() | nil
        }

  @enforce_keys [:name, :arguments]
  defstruct id: nil, name: nil, arguments: %{}, output: nil, ok?: nil

  @doc "Records a call at the end of `exchanges`."
  @spec call([t()], String.t() | nil, String.t(), map()) :: [t()]
  def call(exchanges, id, name, arguments) when is_list(exchanges) and is_binary(name) do
    exchanges ++ [%__MODULE__{id: id, name: name, arguments: arguments || %{}}]
  end

  @doc """
  Completes the call `id` names, or the oldest call of `name` still waiting,
  with its output. A result no call is waiting for is recorded on its own.
  """
  @spec finish([t()], String.t() | nil, String.t(), String.t(), boolean()) :: [t()]
  def finish(exchanges, id, name, output, ok?) when is_list(exchanges) do
    index =
      Enum.find_index(exchanges, &(id != nil and &1.id == id)) ||
        Enum.find_index(exchanges, &(&1.name == name and &1.output == nil))

    case index do
      nil ->
        exchanges ++ [%__MODULE__{id: id, name: name, arguments: %{}, output: output, ok?: ok?}]

      index ->
        List.update_at(exchanges, index, &%{&1 | output: output, ok?: ok?})
    end
  end

  @doc "Whether the call has its result."
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{output: output}), do: output != nil
end
