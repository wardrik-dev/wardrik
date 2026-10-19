defmodule WardrikTUI.Test.Terse do
  @moduledoc "A presenter of a test's own: `resting` between turns, `busy` in one."
  defstruct []

  defimpl Wardrik.Agent.Activity.Presenter do
    def label(_terse, %Wardrik.Agent.Activity{doing: :idle}), do: "resting"
    def label(_terse, _activity), do: "busy"
  end
end
