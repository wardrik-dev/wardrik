defmodule WardrikTUI.Test.Root do
  @moduledoc """
  The issuer of a test's host: whoever uses the TUI holds the node, `owner`
  on every agent, as the daemon's issuer has a terminal or an SSH session.
  """
  defstruct []

  defimpl Wardrik.Issuer do
    def issue(_root, principal, _opts), do: Wardrik.Token.root(principal)
  end
end
