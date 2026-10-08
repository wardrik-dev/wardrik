defmodule WardrikTUI.Exchange.Log do
  @moduledoc """
  A conversation's tool calls, as `WardrikTUI.Exchange` records and completes
  them: each by the order it came in, the first call of each id, and, for
  each tool name, the calls of that name still waiting, oldest first.
  """

  @type t() :: %__MODULE__{
          calls: %{non_neg_integer() => WardrikTUI.Exchange.t()},
          count: non_neg_integer(),
          ids: %{String.t() => non_neg_integer()},
          waiting: %{String.t() => :queue.queue(non_neg_integer())}
        }

  defstruct calls: %{}, count: 0, ids: %{}, waiting: %{}
end
