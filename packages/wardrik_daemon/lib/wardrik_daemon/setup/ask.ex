defmodule WardrikDaemon.Setup.Ask do
  @moduledoc """
  How `wardrik init` answers a setup question: from what's given, at the terminal, or unattended.
  `WardrikDaemon.Setup.Question` and `WardrikDaemon.Setup.Choice` implement it.
  """

  @doc "Returns `given`, from `--set` or `--answers`, as an answer, or why it isn't one."
  @callback cast(question :: struct(), given :: term()) :: {:ok, term()} | {:error, String.t()}

  @doc "Asks a person at the terminal, and returns the answer."
  @callback ask_in_terminal(question :: struct()) :: term()

  @doc "Returns the answer where no one is there to ask and none is given. `flags` has `:yes`."
  @callback answer_unattended(question :: struct(), flags :: map()) :: term()
end
