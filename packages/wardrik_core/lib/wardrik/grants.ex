defprotocol Wardrik.Grants do
  @moduledoc """
  What each person or system that reaches a deployment may do: the
  `Wardrik.Grant`s its host gives a `Wardrik.Principal`, however they came.

  A host names the value once, as the `:grants` of its `Wardrik.Host`,
  and whatever knows someone by their principal alone asks it through
  `Wardrik.Host.caller/2`. The value carries what its implementation needs,
  such as who administers each channel:

      host = Wardrik.Host.new(grants: %MyApp.Grants{admins: admins})

      {:ok, caller} = Wardrik.Host.caller(host, principal: principal, subject: ~A"acme/triage")
      :ok = Wardrik.Agent.decide(~A"acme/triage", decisions, caller)

  A chat channel knows the person pressing a button by their principal, and
  a tool acting for the person who asked for its turn knows them as
  `Wardrik.Tool.Context`'s `:sender`, on the host its run carries. Where
  a host answers who someone is in one place, every surface holds them to
  the same grants. A surface that holds a grant itself, as the HTTP API does
  in its tokens, need not ask.

  A principal may hold several grants, each on its own scope, as someone
  in a channel that offers several orgs' agents holds one in each.

  A host that names none has `Wardrik.Grants.None`: nobody holds anything,
  and `Wardrik.Host.caller/2` finds nothing within anyone's reach.
  """

  alias Wardrik.Grant
  alias Wardrik.Principal

  @doc "What `principal` may do, as one grant on each scope they reach; `[]` for nothing."
  @spec grants(t(), Principal.t()) :: [Grant.t()]
  def grants(grants, principal)
end
