defmodule Wardrik.Token do
  @moduledoc """
  What someone may do with the agents, and who they are: the one value
  every function of `Wardrik` checks before it acts, as an OAuth access
  token, or a session an AWS STS issues, is.

    * `principal` - the `Wardrik.Principal` it acts for, whom the audit
      records as having made each change
    * `scope` - what it allows, as `Wardrik.Statement`s; anything none of
      them states is denied
    * `policy` - the name of the policy every agent it defines runs under,
      ahead of the agent's own: what IAM calls a permissions boundary. The
      host's definitions read it by its name each time such an agent starts,
      as they read the policy a definition names, and the strictest hook
      decides a call, so a definition can narrow it and never loosen it.
      `:none` holds them to nothing more
    * `assumed_by` - who acts with it for the principal, first to last, as
      an agent acting for the person who asked it something; `[]` where the
      principal acts themselves
    * `expires` - when it stops working, or `:infinity`

  A host's `Wardrik.Issuer` issues one to whoever it knows, and
  `Wardrik.as/3` asks it. A surface that keeps tokens, as the HTTP API
  does, holds one for each of its callers.

      token = %Wardrik.Token{
        principal: maria,
        scope: [Wardrik.Role.bind([:reader, :messenger], [Wardrik.Resource.parse!("acme/agent/*")])]
      }

      Wardrik.Token.authorize(token, "agent.ask", ~A"acme/triage")      #=> :ok

  `assume/3` hands a token on to someone acting for its principal, and can
  only narrow what it allows.
  """

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Statement

  @enforce_keys [:principal]
  defstruct [:principal, scope: [], policy: :none, assumed_by: [], expires: :infinity]

  @type t() :: %__MODULE__{
          principal: Principal.t(),
          scope: [Statement.t()],
          policy: String.t() | :none,
          assumed_by: [Principal.t()],
          expires: DateTime.t() | :infinity
        }

  @doc """
  The token of `principal` holding `owner` on `*`, everything: one who holds
  the node itself, as a shell on it does.
  """
  @spec root(Principal.t()) :: t()
  def root(principal),
    do: %__MODULE__{principal: principal, scope: [Role.bind([:owner], [Resource.parse!("*")])]}

  @doc """
  `:ok` where `token` allows `action` on `target`, one agent or a
  resource, or why not: an expired token is `:unauthorized`; a target
  none of its statements reaches is `:not_found`, as if there were none, so
  its holder learns nothing outside its scope; and one they reach without
  the action is `:forbidden`.
  """
  @spec authorize(t(), Statement.action(), Statement.target()) :: :ok | {:error, Error.t()}
  def authorize(%__MODULE__{scope: scope} = token, action, target) when is_binary(action) do
    cond do
      expired?(token) ->
        {:error, Error.new(:unauthorized, "This token has expired.")}

      Enum.any?(scope, &(Statement.reaches?(&1, target) and Statement.allows?(&1, action))) ->
        :ok

      Enum.any?(scope, &Statement.reaches?(&1, target)) ->
        {:error, Error.new(:forbidden, "This token does not allow #{action} on #{target}.")}

      true ->
        {:error, unreached(target)}
    end
  end

  defp unreached(%AgentID{} = id), do: Error.no_agent(id)

  defp unreached(resource),
    do: Error.new(:not_found, "Nothing #{resource} names is within this token's reach.")

  @doc "Whether any statement of `token` allows `action`, on whatever it reaches."
  @spec allows?(t(), Statement.action()) :: boolean()
  def allows?(%__MODULE__{scope: scope}, action),
    do: Enum.any?(scope, &Statement.allows?(&1, action))

  @doc "Whether any statement of `token` reaches `target`, for any action."
  @spec reaches?(t(), Statement.target()) :: boolean()
  def reaches?(%__MODULE__{scope: scope}, target),
    do: Enum.any?(scope, &Statement.reaches?(&1, target))

  @doc "Every resource the statements of `token` name."
  @spec resources(t()) :: [Resource.t()]
  def resources(%__MODULE__{scope: scope}),
    do:
      Enum.uniq(
        for %Statement{resources: resources} <- scope, resource <- resources, do: resource
      )

  @doc "Whether `token` has stopped working."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires: :infinity}), do: false
  def expired?(%__MODULE__{expires: expires}), do: DateTime.after?(DateTime.utc_now(), expires)

  @doc """
  `token`, handed on to `actor`, who acts with it for its principal, as an
  agent acting for the person who asked it does: it allows only what both
  `token` and the `:scope` given allow, names `actor` last of its
  `assumed_by`, and expires at the earlier of when it did and `:expires`,
  where that is given. It never allows more than `token`.

  It keeps `token`'s policy unless `:policy` names another, which takes
  its place: a policy only ever narrows what an agent's own allows, and
  the one the actor names is the one it acts under.
  """
  @spec assume(t(), Principal.t(),
          scope: [Statement.t()],
          expires: DateTime.t() | :infinity,
          policy: String.t() | :none
        ) :: t()
  def assume(%__MODULE__{} = token, actor, opts) do
    opts = Keyword.validate!(opts, [:scope, expires: :infinity, policy: :none])

    %{
      token
      | scope:
          for(
            one <- token.scope,
            other <- Keyword.fetch!(opts, :scope),
            both <- Statement.intersect(one, other),
            do: both
          ),
        assumed_by: token.assumed_by ++ [actor],
        expires: earlier(token.expires, opts[:expires]),
        policy: named(token.policy, opts[:policy])
    }
  end

  defp named(policy, :none), do: policy
  defp named(_policy, name), do: name

  defp earlier(:infinity, other), do: other
  defp earlier(expires, :infinity), do: expires
  defp earlier(expires, other), do: Enum.min([expires, other], DateTime)

  @doc "Who acts with `token`: the last to assume it, or its principal."
  @spec actor(t()) :: Principal.t()
  def actor(%__MODULE__{assumed_by: [], principal: principal}), do: principal
  def actor(%__MODULE__{assumed_by: assumed_by}), do: List.last(assumed_by)
end
