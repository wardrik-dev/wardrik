defmodule Wardrik.Tool.Annotations do
  @moduledoc """
  What a tool declares about its calls, read before any of them runs.

  A tool answers `c:Wardrik.Tool.annotations/1`, or a source
  `c:Wardrik.Tool.annotations/2` for each of its tools, with a map of these,
  leaving out what it has nothing to say about:

    * `:gated` - a call waits on a person unless a hook allows it by name, as
      `WardrikPolicy`'s `allow` rules do; `default: allow` is not enough. For
      a tool whose call cannot be taken back.
    * `:outside` - what the tool answers holds content nobody on the agent's
      side wrote, such as a web page, so a call to it taints its run, and a
      gated tool's call later in the run waits on a person however its hooks
      allowed it.
    * `:in_doubt` - what a call does when whether it had its effect is not
      known: its turn is replayed and the ledger holds it as begun and never
      finished, or the tool answered `{:in_doubt, reason}`. `:ask`, the
      default, parks it for a person, and `:rerun` runs it again, once, under
      the same `Wardrik.Ledger.idempotency_key/2`. Declare `:rerun` for a tool
      that passes that key on to the system it calls, or that changes
      nothing.
    * `:timeout` - how long one call may take, in milliseconds, for work that
      legitimately runs longer than a request; `Wardrik.LLM.ToolRunner` has a
      default.
    * `:credentials` - the credentials a call needs, by the names a
      `Wardrik.Credential` resolver knows them by. The runtime resolves them
      before the call runs and hands them to the tool in its
      `Wardrik.Tool.Context`; one the person has yet to authorize parks the
      call on its link.

      @impl true
      def annotations(_name), do: %{outside: true, timeout: :timer.minutes(5)}
  """

  defstruct gated: false, outside: false, in_doubt: :ask, timeout: nil, credentials: []

  @type t() :: %__MODULE__{
          gated: boolean(),
          outside: boolean(),
          in_doubt: :ask | :rerun,
          timeout: timeout() | nil,
          credentials: [Wardrik.Credential.ref()]
        }

  @doc """
  The annotations `fields` declare, with what they leave out at its default.
  Raises on a field that is not one, which is a bug in the tool.
  """
  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = annotations), do: annotations
  def new(fields) when is_map(fields) or is_list(fields), do: struct!(__MODULE__, fields)
end
