defmodule Wardrik.Definition.None do
  @moduledoc """
  The `Wardrik.Definition` of a host that keeps no definitions: nothing is
  defined, kept, created or read again, so each operation on definitions is
  `:unsupported`, an agent is forgotten with no definition beside it, and
  every agent starts and wakes as it was stored. A `Wardrik.Host` that names
  no `:definitions` has it.
  """

  use Wardrik.Definition
end
