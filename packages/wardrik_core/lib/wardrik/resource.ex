defmodule Wardrik.Resource do
  @moduledoc """
  What something is called, as IAM names resources: a namespace, or what
  is in one, by its type and its name, with what that holds after it.

  | Name | What |
  | --- | --- |
  | `acme` | the org acme |
  | `acme/@jon` | jon, in acme |
  | `deployment` | the deployment itself |
  | `acme/agent/triage` | acme's own agent `triage`, `acme/triage` as `Wardrik.AgentID` writes it |
  | `acme/@jon/agent/triage/thread/1696.1234` | jon's `triage`, answering for `1696.1234` |
  | `acme/agent/triage/trigger/hook` | the trigger `hook` of acme's `triage` |
  | `acme/server/crm` | the MCP server acme added as `crm` |
  | `acme/@jon/secret/github` | what jon connected or sealed as `github` |
  | `deployment/server/github` | the MCP server `github` the deployment's configuration names |
  | `deployment/token/0192…` | an API token |

  A namespace is an org, a user in it, or the deployment, and no org is
  named `deployment`. A type is `agent`, `thread` or `trigger`, both under
  an agent, `server`, `secret` or `token`, and each name is a segment as
  `Wardrik.AgentID` writes one, holding no `*` or `?`. Names are
  case-sensitive.

  ## Patterns

  A pattern is a name with IAM's wildcards: `*` matches any run of
  characters, `/` among them, and `?` any one. `*` is everything, the
  deployment's own included; `acme/*` is the tenant acme, its users' with
  its own; `acme/agent/*` acme's own agents, with their threads and
  triggers. Nothing else is implied: an agent and its threads are
  `acme/agent/triage` and `acme/agent/triage/*`.
  """

  alias Wardrik.AgentID

  @enforce_keys [:name]
  defstruct [:name]

  @type t() :: %__MODULE__{name: String.t()}

  @types ~w(agent thread trigger server secret token)

  @doc "The deployment's namespace."
  @spec deployment() :: t()
  def deployment, do: %__MODULE__{name: "deployment"}

  @doc """
  The name or pattern `text` writes. A name follows the grammar above
  throughout; a pattern up to its first wildcard.

      Wardrik.Resource.parse("acme/agent/*")  #=> {:ok, #Wardrik.Resource<acme/agent/*>}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    segments = String.split(text, "/")
    named = Enum.take_while(segments, &(not String.contains?(&1, ["*", "?"])))

    if written?(named, named == segments),
      do: {:ok, %__MODULE__{name: text}},
      else:
        {:error,
         "#{inspect(text)} is not a resource; one is a namespace, org, org/@user or " <>
           "deployment, with type/name after it, as acme/agent/triage"}
  end

  @doc "`parse/1`, raising `ArgumentError` where it answers an error."
  @spec parse!(String.t()) :: t()
  def parse!(text), do: ok!(parse(text))

  @doc """
  What `within` holds as each `type: name` of `pairs` in turn, raising
  `ArgumentError` where a name is not a segment.

      Wardrik.Resource.new(Wardrik.Resource.deployment(), server: "github")
      #=> #Wardrik.Resource<deployment/server/github>
  """
  @spec new(t(), keyword(String.t())) :: t()
  def new(%__MODULE__{name: name}, pairs) when is_list(pairs) do
    if Enum.all?(pairs, fn {_type, segment} -> AgentID.segment?(segment) end),
      do:
        parse!(
          Enum.join([name | Enum.map(pairs, fn {type, segment} -> "#{type}/#{segment}" end)], "/")
        ),
      else: raise(ArgumentError, "#{inspect(pairs)} holds a name that is not a segment")
  end

  @doc "The namespace `resource` is in: `acme/@jon` of `acme/@jon/agent/triage`, itself for a namespace."
  @spec owner(t()) :: t()
  def owner(%__MODULE__{name: name}) do
    case String.split(name, "/", parts: 3) do
      [org, "@" <> _user = user | _rest] -> %__MODULE__{name: org <> "/" <> user}
      [namespace | _rest] -> %__MODULE__{name: namespace}
    end
  end

  @doc """
  The org `resource` is in, as its namespace: `acme` of `acme/@jon/agent/triage`,
  itself for an org's, and the deployment for the deployment's.
  """
  @spec org(t()) :: t()
  def org(%__MODULE__{name: name}),
    do: %__MODULE__{name: name |> String.split("/", parts: 2) |> hd()}

  @doc "The name `resource` ends in: `crm` of `acme/server/crm`."
  @spec basename(t()) :: String.t()
  def basename(%__MODULE__{name: name}), do: name |> String.split("/") |> List.last()

  @doc """
  Whether `pattern` covers `target`, a name or a pattern of its own: every
  name `target` matches, `pattern` does too.
  """
  @spec covers?(t(), t()) :: boolean()
  def covers?(%__MODULE__{name: pattern}, %__MODULE__{name: target}),
    do: matches?(pattern, target)

  # Read a character at a time, so nothing is compiled for a call. A `?`
  # meets one character of the target, never a `*` that stands for many,
  # so a pattern covers another only where it covers all it matches.
  defp matches?(<<>>, <<>>), do: true
  defp matches?(<<?*, pattern::binary>>, <<>>), do: matches?(pattern, <<>>)

  defp matches?(<<?*, rest::binary>> = pattern, <<_char::utf8, tail::binary>> = target),
    do: matches?(rest, target) or matches?(pattern, tail)

  defp matches?(<<??, pattern::binary>>, <<char::utf8, tail::binary>>) when char != ?*,
    do: matches?(pattern, tail)

  defp matches?(<<char::utf8, pattern::binary>>, <<char::utf8, tail::binary>>),
    do: matches?(pattern, tail)

  defp matches?(_pattern, _target), do: false

  defp written?(["deployment" | pairs], whole?), do: pairs?(pairs, whole?)

  defp written?([org, "@" <> user | pairs], whole?),
    do: AgentID.org?(org) and AgentID.segment?(user) and pairs?(pairs, whole?)

  defp written?([org | pairs], whole?), do: AgentID.org?(org) and pairs?(pairs, whole?)
  defp written?([], whole?), do: not whole?

  defp pairs?([], _whole?), do: true
  defp pairs?([type], whole?), do: type in @types and not whole?

  defp pairs?([type, name | pairs], whole?),
    do: type in @types and AgentID.segment?(name) and pairs?(pairs, whole?)

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  defimpl String.Chars do
    def to_string(%{name: name}), do: name
  end

  defimpl Inspect do
    def inspect(%{name: name}, _opts), do: "#Wardrik.Resource<" <> name <> ">"
  end
end
