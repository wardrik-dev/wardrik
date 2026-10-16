defmodule Wardrik.Change do
  @moduledoc """
  A change a `Wardrik.Command` planned, and has not made: the request it
  answers, and its `Wardrik.Effect`, what the plan worked out it will do.

  A change is data, so it can be shown before it is made, asked about, or
  kept until a person agrees to it, and made later with
  `Wardrik.Command.make/2`, which does what the effect says and no more.
  """

  @enforce_keys [:request, :effect]
  defstruct [:request, :effect]

  @type t() :: %__MODULE__{request: struct(), effect: Wardrik.Effect.t()}

  @doc "A change that makes `request`, which says all it does: its own effect."
  @spec new(struct()) :: t()
  def new(request) when is_struct(request), do: new(request, request)

  @doc "A change that makes `request` by doing `effect`."
  @spec new(struct(), Wardrik.Effect.t()) :: t()
  def new(request, effect) when is_struct(request) and is_struct(effect),
    do: %__MODULE__{request: request, effect: effect}
end
