defmodule WardrikChannel.Channel do
  @moduledoc """
  A channel as a node runs it: its name, its adapter, the options its
  adapter's `config/1` answered, and its `WardrikChannel.Context`.
  `WardrikChannel.channels/2` makes them, once, as a host starts.
  """

  @enforce_keys [:name, :adapter, :options, :context]
  defstruct [:name, :adapter, :options, :context]

  @type t() :: %__MODULE__{
          name: String.t(),
          adapter: module(),
          options: keyword(),
          context: WardrikChannel.Context.t()
        }

  @doc "What the adapter's callbacks are given: its options, its `:name` and its `:context`."
  @spec options(t()) :: keyword()
  def options(%__MODULE__{} = channel),
    do: [name: channel.name, context: channel.context] ++ channel.options
end
