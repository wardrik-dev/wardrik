defmodule Wardrik.Policy.Spending.Counted do
  @moduledoc false

  # What a turn's measurements were when spending last counted them, so a restart counts only
  # what came after.

  @behaviour WardrikCore.Format

  @impl WardrikCore.Format
  def type, do: "policy_counted"

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(%{trace: trace, counted: counted}) do
    %{
      "trace" => trace,
      "counted" => Map.new(counted, fn {measure, amount} -> {Atom.to_string(measure), amount} end)
    }
  end

  # A measure is one the app counts, so its atom exists once it runs.
  @impl WardrikCore.Format
  def load(1, %{"trace" => trace, "counted" => counted}) do
    {:ok,
     %{
       trace: trace,
       counted:
         Map.new(counted, fn {measure, amount} -> {String.to_existing_atom(measure), amount} end)
     }}
  rescue
    ArgumentError -> {:error, "it counted a measure this release doesn't have"}
  end
end
