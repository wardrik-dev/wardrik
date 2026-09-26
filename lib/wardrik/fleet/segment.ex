defprotocol Wardrik.Fleet.Segment do
  @moduledoc """
  How a host's own value names itself in a fleet key.

  `Wardrik.Fleet` builds an agent's key from the `:org` and `:user` a scope
  carries, which are the host's own values and may be any term. This is the one
  place a host says how to write one down.

      defimpl Wardrik.Fleet.Segment, for: MyApp.Accounts.User do
        def to_segment(user), do: to_string(user.id)
      end

  Return something stable and unique within its scope. It is the address an
  agent is reached by, so two users that write themselves down the same way are
  one user as far as the cluster is concerned.

  A segment may not contain `/`, which separates the parts of a key.
  Implemented already for strings, atoms and integers.
  """

  @doc "The key segment naming this value."
  @spec to_segment(t()) :: String.t()
  def to_segment(value)
end

defimpl Wardrik.Fleet.Segment, for: BitString do
  def to_segment(string), do: string
end

defimpl Wardrik.Fleet.Segment, for: Atom do
  def to_segment(atom), do: Atom.to_string(atom)
end

defimpl Wardrik.Fleet.Segment, for: Integer do
  def to_segment(integer), do: Integer.to_string(integer)
end
