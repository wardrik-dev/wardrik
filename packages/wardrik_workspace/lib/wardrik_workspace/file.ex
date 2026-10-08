defmodule WardrikWorkspace.File do
  @moduledoc """
  One file in a workspace, as a `WardrikWorkspace.Backend` keeps it: its
  content, and who wrote it last.

    * `:content` - the whole file, as text
    * `:by` - who wrote it: an agent's key, or a person's principal
    * `:run` - the run it was written in, for an agent
    * `:call` - the idempotency key of the call that wrote it, so a call run
      again after a lost node finds its own write and does not make it twice
    * `:labels` - the `Wardrik.Label`s of what the runs that wrote what it
      holds had read, so reading it labels the reader's run in turn
    * `:at` - when it was written
  """

  @enforce_keys [:content]
  defstruct [:content, :by, :run, :call, :at, labels: []]

  @type t() :: %__MODULE__{
          content: String.t(),
          by: String.t() | nil,
          run: String.t() | nil,
          call: String.t() | nil,
          labels: [Wardrik.Label.t()],
          at: DateTime.t() | nil
        }
end
