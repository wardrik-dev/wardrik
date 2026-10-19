defmodule Wardrik.Principal do
  @moduledoc """
  Who did something: the person or system behind a decision, by the name
  they are known by, and the name they go by where one is known.

      Wardrik.Principal.new("acme/@jon", name: "Jon")

  One Wardrik knows as a resource is named as `Wardrik.Resource` names
  it, with no wildcard in it:

  | Name | Who |
  | --- | --- |
  | `acme` | the org acme |
  | `acme/@jon` | jon, a person in acme: a user |
  | `deployment` | the deployment itself; see `deployment/0` |
  | `acme/agent/triage` | acme's agent `triage`, acting through its tools, on itself or on another agent, or answering one that asked it something; see `Wardrik.Catalog.Tools` |
  | `acme/@jon/agent/triage/thread/1696.1234` | jon's `triage`, answering for `1696.1234` |
  | `acme/agent/triage/trigger/hook` | a request from outside to the trigger `hook` of acme's `triage`: whoever sent it is known only by the secret its signature was made with |

  Anyone else is named where they reached Wardrik, as `provider:subject`:
  a provider of lower-case letters, digits and `-`, beginning with a
  letter, then what it knows them as, holding no whitespace.

  | Name | Who |
  | --- | --- |
  | `slack:T0123/U024BE7LH` | someone in the chat channel `slack`, by the workspace it is installed in and the id it knows them by there; see `WardrikChannel.principal/2` |
  | `shell:jon` | the operating system account `jon` on the node, through `bin/wardrik` |
  | `ssh:jon` | an SSH session to the TUI, by the name the client connected as |
  | `terminal:jon` | a TUI started in a terminal on the node, by the account running it |
  | `oauth:github` | an authorization flow for `github` that finished: whoever completed it is not known |

  No segment of a resource's name holds a `:`, so the two never meet. A
  host's `Wardrik.Issuer` reads the name to decide what the principal may
  do, parsing what it needs of it there; nothing else decides by it.
  """

  alias Wardrik.Resource

  @enforce_keys [:id]
  defstruct [:id, :name]

  @opaque t() :: %__MODULE__{id: String.t(), name: String.t() | nil}

  @provider ~r/\A[a-z][a-z0-9-]*\z/
  @subject ~r/\A\S+\z/u

  @doc """
  The principal known as `id`, and by `name:` where they go by one. Raises
  `ArgumentError` unless `id` is a resource's name or `provider:subject`.

      Wardrik.Principal.new("slack:T0123/U024BE7LH", name: "jon")
  """
  @spec new(String.t(), name: String.t() | nil) :: t()
  def new(id, opts \\ []) when is_binary(id) and is_list(opts) do
    opts = Keyword.validate!(opts, [:name])

    if federated?(id) or resource?(id),
      do: %__MODULE__{id: id, name: opts[:name]},
      else:
        raise(
          ArgumentError,
          "#{inspect(id)} names no principal; one is a resource, as acme/@jon or " <>
            "acme/agent/triage, or provider:subject, as slack:T0123/U024BE7LH"
        )
  end

  @doc "The deployment's own principal, `deployment`."
  @spec deployment() :: t()
  def deployment, do: %__MODULE__{id: "deployment"}

  @doc """
  Whether `text` can be the provider of a `provider:subject` name:
  lower-case letters, digits and `-`, beginning with a letter.
  """
  @spec provider?(term()) :: boolean()
  def provider?(text) when is_binary(text), do: Regex.match?(@provider, text)
  def provider?(_text), do: false

  @doc """
  Whether `text` can be the subject of a `provider:subject` name: text,
  holding no whitespace.
  """
  @spec subject?(term()) :: boolean()
  def subject?(text) when is_binary(text), do: Regex.match?(@subject, text)
  def subject?(_text), do: false

  @doc "The name the principal is known by."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}), do: id

  @doc "The name they go by, where one is known."
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{name: name}), do: name

  @doc """
  Whether `a` and `b` are the same person or system: known by the same
  name, whatever name each goes by. Nobody, `nil`, is never anyone.
  """
  @spec same?(t() | nil, t() | nil) :: boolean()
  def same?(%__MODULE__{id: id}, %__MODULE__{id: id}), do: true
  def same?(_a, _b), do: false

  defp federated?(id) do
    case String.split(id, ":", parts: 2) do
      [provider, subject] -> provider?(provider) and subject?(subject)
      [_resource] -> false
    end
  end

  defp resource?(id),
    do: not String.contains?(id, ["*", "?"]) and match?({:ok, _resource}, Resource.parse(id))
end
