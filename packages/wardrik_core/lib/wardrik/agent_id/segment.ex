defprotocol Wardrik.AgentID.Segment do
  @moduledoc """
  How a host's own value names itself in an agent's ID.

  `Wardrik.AgentID.new/2` takes the org, user and thread as the host's own
  values, which may be any term. This is the one place a host says how to
  write one down.

      defimpl Wardrik.AgentID.Segment, for: MyApp.Accounts.User do
        def to_segment(user), do: to_string(user.id)
      end

  Return something stable and unique within its scope. It is the address an
  agent is reached by, so two users that write themselves down the same way are
  one user as far as the cluster is concerned.

  A segment may not contain `/`, which separates the parts of an ID.
  Implemented already for strings, atoms and integers.
  """

  @doc "The ID segment naming this value."
  @spec to_segment(t()) :: String.t()
  def to_segment(value)
end

defimpl Wardrik.AgentID.Segment, for: BitString do
  def to_segment(string), do: string
end

defimpl Wardrik.AgentID.Segment, for: Atom do
  def to_segment(atom), do: Atom.to_string(atom)
end

defimpl Wardrik.AgentID.Segment, for: Integer do
  def to_segment(integer), do: Integer.to_string(integer)
end
