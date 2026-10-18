defprotocol Wardrik.Agent.Activity.Presenter do
  @moduledoc """
  Words for a `Wardrik.Agent.Activity`, for a surface to show while an agent
  works.

  A surface takes a presenter as an option, `Wardrik.Agent.Activity.English`
  unless it is given another, so a host words it its own way by implementing
  this protocol for a struct of its own:

      defmodule MyApp.Terse do
        defstruct []
      end

      defimpl Wardrik.Agent.Activity.Presenter, for: MyApp.Terse do
        def label(_terse, %Wardrik.Agent.Activity{doing: :idle}), do: ""
        def label(_terse, _activity), do: "…"
      end
  """

  @doc "What `activity` reads as, in a few words."
  @spec label(t(), Wardrik.Agent.Activity.t()) :: String.t()
  def label(presenter, activity)
end
