defprotocol Wardrik.Specs do
  @moduledoc """
  Where the agents a host defines start from: the `Wardrik.Agent.Spec` each
  runs on, as the host's definitions write it now.

  A host names the value once, as the `:definitions` of its `Wardrik.Host`.
  An agent asks it as it starts, wakes, or restarts on another node, and
  `Wardrik.Fleet` asks it of an agent the store does not hold, and of the
  agents it lists. `Wardrik.Definitions`, of the `wardrik` package, is the
  one an application embedding Wardrik has, and the daemon's; a host that
  defines none has `Wardrik.Specs.None`.

      host = Wardrik.Host.new(definitions: %MyApp.Specs{store: store})
      children = [{Wardrik.Core, host: host}]
  """

  @doc """
  The spec the agent `id` runs on now, from the definition kept of it, on
  the `:host` asking, whose tools, sources and runtimes it names; or `:none`
  where none is kept. An agent, and each `Wardrik.Thread` of it, takes it as
  it starts, wakes, or restarts on another node, so a definition changed
  while it slept is the one it wakes with, and `Wardrik.Fleet` starts from
  it an agent or thread the store does not hold.
  """
  @spec current(t(), Wardrik.AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Wardrik.Agent.Spec.t()} | :none
  def current(specs, id, opts)

  @doc """
  The agents a definition is kept for that the `Wardrik.Resource` pattern
  covers, found without building any, so `Wardrik.Fleet.list/2` lists
  those not yet started.
  """
  @spec defined(t(), Wardrik.Resource.t()) :: [Wardrik.AgentID.t()]
  def defined(specs, pattern)
end
