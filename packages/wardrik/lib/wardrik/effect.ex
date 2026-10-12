defprotocol Wardrik.Effect do
  @moduledoc """
  What a `Wardrik.Command` does, as data: what its plan worked out it will
  do, and, once it is made, what it did.

  A command whose request says all it does is its own effect, as a message
  to send is. One that has to work something out first answers an effect of
  its own, as the agents a cancel under a prefix reaches. Either way every
  surface shows the same preview before it is made, and the audit records
  what was made.
  """

  @doc "What the effect does, as `JSON.encode!/1` takes it, as every surface shows it."
  @spec preview(t()) :: map()
  def preview(effect)

  @doc "What `Wardrik.Audit` records once it is made, an entry each, none or more."
  @spec audit(t()) :: [Wardrik.Audit.action()]
  def audit(effect)
end
