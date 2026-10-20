defmodule Wardrik.Instance.Issuer do
  @moduledoc false
  # The token each principal acts with on a `use Wardrik` instance's agents,
  # by the name it is known by:
  #
  #   * someone in an org, as `acme/@42`: what the instance's grants/1 says
  #   * an agent, or a thread of one, acting through its tools: reader and
  #     messenger on its owner's agents, as it could itself
  #   * the app itself, `deployment`: reading every agent and its events,
  #     what notices, channels' replies and listeners follow
  #   * anyone else, such as a request to a trigger: nothing

  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Statement
  alias Wardrik.Token

  @enforce_keys [:module]
  defstruct [:module]

  @type t() :: %__MODULE__{module: module()}

  @doc false
  def issue(%__MODULE__{module: module}, principal),
    do: %Token{principal: principal, scope: scope(module, Principal.id(principal))}

  defp scope(_module, "deployment"),
    do: [
      %Statement{
        actions: ["agent.events", "agent.read"],
        resources: [Resource.parse!("*/agent/*")]
      }
    ]

  defp scope(module, id) do
    case Resource.parse(id) do
      {:ok, resource} -> named(module, String.split(id, "/"), resource)
      {:error, _known_elsewhere} -> []
    end
  end

  defp named(module, [org, "@" <> id], _resource), do: granted(module, %{org: org, id: id})

  defp named(_module, segments, resource) do
    owner = Resource.owner(resource)

    case Enum.drop(segments, length(String.split(to_string(owner), "/"))) do
      ["agent", _agent] -> acting(owner)
      ["agent", _agent, "thread", _thread] -> acting(owner)
      _other -> []
    end
  end

  defp acting(owner),
    do: [Role.bind([:reader, :messenger], [Resource.parse!("#{owner}/agent/*")])]

  defp granted(module, who), do: for(grant <- module.grants(who), do: bind(module, who, grant))

  defp bind(module, who, {role, reach} = grant) when is_atom(role) do
    case Role.parse([Atom.to_string(role)]) do
      {:ok, [role]} -> Role.bind([role], [reach(module, who, reach, grant)])
      {:error, message} -> raise ArgumentError, ungranted(module, grant, message)
    end
  end

  defp bind(module, _who, grant),
    do: raise(ArgumentError, ungranted(module, grant, "a grant is {role, :own | :org | pattern}"))

  defp reach(_module, %{org: org, id: id}, :own, _grant), do: Resource.parse!("#{org}/@#{id}/*")
  defp reach(_module, %{org: org}, :org, _grant), do: Resource.parse!("#{org}/agent/*")

  defp reach(module, _who, pattern, grant) when is_binary(pattern) do
    case Resource.parse(pattern) do
      {:ok, resource} -> resource
      {:error, message} -> raise ArgumentError, ungranted(module, grant, message)
    end
  end

  defp reach(module, _who, _reach, grant),
    do: raise(ArgumentError, ungranted(module, grant, "it reaches :own, :org or a pattern"))

  defp ungranted(module, grant, why),
    do: "#{inspect(module)}.grants/1 answered #{inspect(grant)}: #{why}"
end

defimpl Wardrik.Issuer, for: Wardrik.Instance.Issuer do
  def issue(issuer, principal, _opts), do: Wardrik.Instance.Issuer.issue(issuer, principal)
end
