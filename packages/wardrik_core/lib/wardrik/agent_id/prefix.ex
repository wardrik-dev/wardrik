defmodule Wardrik.AgentID.Prefix do
  @moduledoc """
  The agents under a prefix: every agent, an org's, one user's, or one agent
  with every external ID it answers for. `Wardrik.Fleet` lists, watches and stops agents
  by prefix, and a `Wardrik.Statement` reaches the agents under one.

  | Text | Covers |
  | --- | --- |
  | `""` | every agent |
  | `acme/*` | acme's agents and every one of its users', the whole tenant |
  | `acme/` | acme's own agents, none of its users' |
  | `acme/@jon/` | jon's agents in acme |
  | `acme/triage` | acme's `triage`, for every external ID |
  | `acme/triage/1696.1234` | acme's `triage` for `1696.1234` alone |

  A prefix covers an ID where the ID's segments begin with the prefix's, so
  `acme/triage` covers `acme/triage/1696.1234` and not `acme/triage2`, and
  where it names the agent's owner whole: an agent that works for a user is
  under a prefix naming that user, or under every agent's, and never under
  its org's alone. An org's agents and each of its users' are apart, so
  whatever reaches one of them reaches none of the others, unless it says it
  reaches them all: `acme/*` is the tenant, for whatever acts across it, as a
  tool worker serving every agent in it, or an operator looking over it.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Segment

  @enforce_keys [:segments]
  defstruct [:segments]

  @opaque t() :: %__MODULE__{segments: [String.t()]}

  @doc "Every agent."
  @spec all() :: t()
  def all, do: %__MODULE__{segments: []}

  @doc """
  The agents of `:org`, or of `:user` in it, each written down through
  `Wardrik.AgentID.Segment`. With neither, every agent.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) when is_list(opts) do
    case {Keyword.get(opts, :org), Keyword.get(opts, :user)} do
      {nil, nil} -> {:ok, all()}
      {nil, _user} -> {:error, "a user's prefix names their org too"}
      {org, nil} -> written([Segment.to_segment(org)])
      {org, user} -> written([Segment.to_segment(org), "@" <> Segment.to_segment(user)])
    end
  end

  @doc """
  The tenant `org`: its own agents and every one of its users', written
  `acme/*`.
  """
  @spec tenant(term()) :: {:ok, t()} | {:error, String.t()}
  def tenant(org), do: written([Segment.to_segment(org), "*"])

  @doc "`tenant/1`, raising `ArgumentError` where it answers an error."
  @spec tenant!(term()) :: t()
  def tenant!(org), do: ok!(tenant(org))

  @doc "`new/1`, raising `ArgumentError` where it answers an error."
  @spec new!(keyword()) :: t()
  def new!(opts), do: ok!(new(opts))

  @doc "The agent `id` names, with every external ID it answers for."
  @spec of(AgentID.t()) :: t()
  def of(%AgentID{} = id), do: %__MODULE__{segments: AgentID.segments(id)}

  @doc """
  The agents of `id`'s owner: its org's own, or those of the user in it it
  works for.
  """
  @spec owner(AgentID.t()) :: t()
  def owner(%AgentID{org: org, user: user}), do: new!(org: org, user: user)

  @doc """
  The agents of the namespace `owner`, a `Wardrik.Resource`: an org's own,
  a user's, or every agent for the deployment's.
  """
  @spec owned_by(Wardrik.Resource.t()) :: t()
  def owned_by(owner) do
    if owner == Wardrik.Resource.deployment(), do: all(), else: parse!("#{owner}/")
  end

  @doc "The org whose agents `prefix` is under, or `nil` for every agent."
  @spec org(t()) :: String.t() | nil
  def org(%__MODULE__{segments: [org | _rest]}), do: org
  def org(%__MODULE__{segments: []}), do: nil

  @doc "The user whose agents `prefix` is under, or `nil` where it names none."
  @spec user(t()) :: String.t() | nil
  def user(%__MODULE__{segments: [_org, "@" <> user | _rest]}), do: user
  def user(%__MODULE__{}), do: nil

  @doc """
  Whether `id`, or every agent under another prefix, is under `prefix`: its
  segments begin with the prefix's, and the prefix names its owner whole,
  the org and the user it works for, where it works for one. Every agent is
  under `all/0`.
  """
  @spec covers?(t(), AgentID.t() | t()) :: boolean()
  def covers?(%__MODULE__{segments: segments}, %AgentID{} = id),
    do: under?(segments, AgentID.segments(id))

  def covers?(%__MODULE__{segments: segments}, %__MODULE__{segments: inner}),
    do: under?(segments, inner)

  defp under?([], _inner), do: true
  defp under?([org, "*"], inner), do: List.starts_with?(inner, [org])

  defp under?(segments, inner),
    do: List.starts_with?(inner, segments) and List.starts_with?(segments, owned(inner))

  defp owned([org, "*" | _rest]), do: [org, "*"]
  defp owned([org, "@" <> _user = user | _rest]), do: [org, user]
  defp owned([org | _rest]), do: [org]
  defp owned([]), do: []

  @doc """
  The prefix `text` writes: `""` for every agent, `acme/*` for a tenant,
  `acme` or `acme/` for an org's own, `acme/@jon` or `acme/@jon/` for one
  user's, or an ID for that agent and every external ID it answers for.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(""), do: {:ok, all()}

  def parse(text) when is_binary(text) do
    trimmed = String.trim_trailing(text, "/")

    case String.split(trimmed, "/") do
      [org] -> scoped([org], text)
      [org, "*"] -> scoped([org, "*"], text)
      [org, "@" <> _user = user] -> scoped([org, user], text)
      _id -> agent(AgentID.parse(trimmed), text)
    end
  end

  @doc "`parse/1`, raising `ArgumentError` where it answers an error."
  @spec parse!(String.t()) :: t()
  def parse!(text), do: ok!(parse(text))

  @doc """
  The prefix `text` names, as `Wardrik.AgentID.expand/2` reads an ID: `""`
  for every agent, `@jon/` for a user in `org`, or a name in it. Text that
  ends in `/` is an org's or a user's; any other names one agent.
  """
  @spec expand(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def expand("", _org), do: {:ok, all()}

  def expand(text, org) when is_binary(text) do
    case String.split(text, "/") do
      ["@" <> _user, ""] -> AgentID.in_org(text, org, &parse/1)
      [_org, ""] -> parse(text)
      [_org, "*"] -> parse(text)
      [_org, "@" <> _user, ""] -> parse(text)
      _id -> with {:ok, id} <- AgentID.expand(text, org), do: {:ok, of(id)}
    end
  end

  @doc false
  @spec patterns(t()) :: [:all | String.t()]
  def patterns(%__MODULE__{segments: []}), do: [:all]
  def patterns(%__MODULE__{segments: [org, "*"]}), do: [org <> "/"]

  def patterns(%__MODULE__{segments: segments} = prefix) do
    case kind(segments) do
      :scope -> [to_string(prefix)]
      :agent -> [to_string(prefix), to_string(prefix) <> "/"]
    end
  end

  defp scoped(segments, text) do
    case written(segments) do
      {:ok, _prefix} = ok -> ok
      {:error, _message} -> {:error, not_a_prefix(text)}
    end
  end

  defp agent({:ok, id}, _text), do: {:ok, of(id)}
  defp agent({:error, _message}, text), do: {:error, not_a_prefix(text)}

  defp written([org] = segments), do: checked(segments, [org])
  defp written([org, "*"] = segments), do: checked(segments, [org])
  defp written([org, "@" <> user] = segments), do: checked(segments, [org, user])

  defp checked(segments, plain) do
    if Enum.all?(plain, &AgentID.segment?/1),
      do: {:ok, %__MODULE__{segments: segments}},
      else: {:error, "#{Enum.join(segments, "/")}/ is not a prefix of agent IDs"}
  end

  defp kind([_org]), do: :scope
  defp kind([_org, "@" <> _user]), do: :scope
  defp kind(_segments), do: :agent

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  defp not_a_prefix(text),
    do: "#{inspect(text)} is not a prefix; a prefix is org/*, org/, org/@user/ or an agent ID"

  defimpl String.Chars do
    def to_string(%{segments: []}), do: ""

    def to_string(%{segments: [_org] = segments}), do: Enum.join(segments ++ [""], "/")
    def to_string(%{segments: [_org, "*"] = segments}), do: Enum.join(segments, "/")

    def to_string(%{segments: [_org, "@" <> _user] = segments}),
      do: Enum.join(segments ++ [""], "/")

    def to_string(%{segments: segments}), do: Enum.join(segments, "/")
  end

  defimpl Inspect do
    def inspect(prefix, _opts), do: "#Wardrik.AgentID.Prefix<" <> to_string(prefix) <> ">"
  end
end
