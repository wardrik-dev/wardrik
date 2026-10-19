defprotocol Wardrik.Issuer do
  @moduledoc """
  Who may do what, as the host says: the `Wardrik.Token` it issues each
  `Wardrik.Principal` it knows, however they came, as an OAuth
  authorization server or AWS STS issues one.

  A host names the value once, as the `:issuer` of its `Wardrik.Host`, and
  `Wardrik.as/3` asks it, as does whatever knows someone by their principal
  alone, such as a chat channel knowing whoever posts, or an agent's tools
  acting for whoever asked it something. The value carries what its
  implementation needs, such as who administers each channel:

      host = Wardrik.Host.new(issuer: %MyApp.Issuer{admins: admins})

      scope = Wardrik.as(host, principal)

  An issuer may decide by how someone reached the deployment,
  `Wardrik.Principal.type/1`; nothing else does. Where a host answers who
  someone is in one place, every surface holds them to the same token. A
  surface that holds a token of its own for its callers, as the HTTP API
  does, need not ask.

  A token `Wardrik.as/3` makes of what it issues expires as the host's
  `:session` expiry says (see `Wardrik.Host`). Once it has, `Wardrik`'s
  functions refresh it through the issuer as they use it, so a change to
  what the issuer gives someone reaches what they hold at its next use.

  A host that names none has `Wardrik.Issuer.None`, whose tokens allow
  nothing.
  """

  @doc """
  The token `principal` acts with. `opts` are those `Wardrik.as/3` was
  given, for the issuer to read as it reads them.
  """
  @spec issue(t(), Wardrik.Principal.t(), keyword()) :: Wardrik.Token.t()
  def issue(issuer, principal, opts)
end
