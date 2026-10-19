defmodule Wardrik.AgentID do
  @moduledoc """
  Which agent: the org it belongs to, the user it works for if it works for
  one, and its name.

  An agent's ID is its address across the cluster and its topic on the event
  bus, a `Wardrik.AgentAddress` as each of its `Wardrik.Thread`s is. It is
  built once, where a host or a person names an agent, and carried as this
  value from there on; its text is written only where something outside the
  BEAM needs it, such as an HTTP path or an event. A store key names the
  agent by its `resource/1`, which `Wardrik.Resource.address/1` reads back.

  | Text | The agent |
  | --- | --- |
  | `acme/triage` | acme's own `triage` |
  | `acme/@jon/triage` | jon's `triage`, in acme |

      id = Wardrik.AgentID.new!("researcher", org: current_org, user: current_user)
      Wardrik.Fleet.spawn(id, config: config)

  `new/2` writes the host's own org and user values down through
  `Wardrik.AgentID.Segment`. A segment is the org, the user, the name or a
  thread's ID. It holds no `/` or whitespace, nor `*` or `?`, which patterns
  are written with, nor `:`, which a `Wardrik.Principal` known elsewhere is
  named with, and does not begin with `@`, which marks the user, or
  `_`, which is kept for the fleet's own records. No org is named
  `deployment`, which names the deployment itself. A segment
  is in every event's `source`, every store key and every log line naming the
  agent, so a user's should be an opaque id rather than an email address.

  The name a `Wardrik.Statement` gives an agent is its `resource/1`, and a
  fleet is sliced by `Wardrik.Resource` patterns those names match.

  `~A` reads an ID's text when the code is compiled:

      import Wardrik.AgentID, only: [sigil_A: 2]
      ~A"acme/@jon/triage"
  """

  alias Wardrik.AgentID.Segment
  alias Wardrik.Resource

  @enforce_keys [:org, :name]
  defstruct [:org, :user, :name]

  @type t() :: %__MODULE__{org: String.t(), user: String.t() | nil, name: String.t()}

  @segment ~r/\A[^\/:@_\s*?][^\/:\s*?]*\z/u

  @doc """
  The ID of the agent named `name` in `:org`, working for `:user` where one
  is given. Each is written down through `Wardrik.AgentID.Segment`.
  """
  @spec new(term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(name, opts) when is_list(opts) do
    with {:ok, org} <- part(Keyword.get(opts, :org), "org"),
         {:ok, name} <- part(name, "name"),
         {:ok, user} <- optional(Keyword.get(opts, :user), "user") do
      {:ok, %__MODULE__{org: org, user: user, name: name}}
    end
  end

  @doc "`new/2`, raising `ArgumentError` where it answers an error."
  @spec new!(term(), keyword()) :: t()
  def new!(name, opts), do: ok!(new(name, opts))

  @doc "Whether `text` can be one segment of an ID: an org, a user, a name or a thread's ID."
  @spec segment?(term()) :: boolean()
  def segment?(text) when is_binary(text),
    do: text not in [".", ".."] and Regex.match?(@segment, text)

  def segment?(_text), do: false

  @doc "Whether `text` can be an org: a segment other than `deployment`."
  @spec org?(term()) :: boolean()
  def org?(text), do: segment?(text) and text != "deployment"

  @doc """
  The resource `id` names, as a `Wardrik.Statement` names it.

      Wardrik.AgentID.resource(~A"acme/@jon/triage")
      #=> #Wardrik.Resource<acme/@jon/agent/triage>
  """
  @spec resource(t()) :: Resource.t()
  def resource(%__MODULE__{org: org, user: user, name: name}) do
    owner = if user, do: [org, "@" <> user], else: [org]
    %Resource{name: Enum.join(owner ++ ["agent", name], "/")}
  end

  @doc """
  The ID `text` writes, as `to_string/1` writes one. A thread's text names
  no agent; `address/1` reads either.

      Wardrik.AgentID.parse("acme/@jon/triage")  #=> {:ok, ~A"acme/@jon/triage"}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    case text |> String.split("/") |> from_segments() do
      {:ok, id} -> {:ok, id}
      :error -> {:error, not_an_id(text)}
    end
  end

  @doc "`parse/1`, raising `ArgumentError` where it answers an error."
  @spec parse!(String.t()) :: t()
  def parse!(text), do: ok!(parse(text))

  @doc """
  The agent or the `Wardrik.Thread` `text` names, as `to_string/1` writes
  either.

      Wardrik.AgentID.address("acme/triage/C1-1696.1234")
      #=> {:ok, #Wardrik.Thread<acme/triage/C1-1696.1234>}
  """
  @spec address(String.t()) :: {:ok, Wardrik.AgentAddress.t()} | {:error, String.t()}
  def address(text) when is_binary(text) do
    with {:error, _not_an_agent} <- parse(text),
         {:error, _not_a_thread} <- Wardrik.Thread.parse(text),
         do: {:error, not_an_id(text) <> ", with a thread's ID after it where it names a thread"}
  end

  @doc "`address/1`, raising `ArgumentError` where it answers an error."
  @spec address!(String.t()) :: Wardrik.AgentAddress.t()
  def address!(text), do: ok!(address(text))

  @doc """
  The agent or the `Wardrik.Thread` `text` names, as `address/1` reads it,
  where an agent in `org` may be named without it: an org's own agent by
  its name, and a user's as `@user/name`. With `org` `nil`, `text` has to
  name its org.

      Wardrik.AgentID.expand("triage", "app")            #=> {:ok, ~A"app/triage"}
      Wardrik.AgentID.expand("@jon/triage", "app")       #=> {:ok, ~A"app/@jon/triage"}
      Wardrik.AgentID.expand("acme/@jon/triage", "app")  #=> {:ok, ~A"acme/@jon/triage"}
  """
  @spec expand(String.t(), String.t() | nil) ::
          {:ok, Wardrik.AgentAddress.t()} | {:error, String.t()}
  def expand(text, org) when is_binary(text) do
    case String.split(text, "/") do
      [_name] -> in_org(text, org, &parse/1)
      ["@" <> _user, _name] -> in_org(text, org, &parse/1)
      _whole -> address(text)
    end
  end

  @doc false
  @spec in_org(String.t(), String.t() | nil, (String.t() -> {:ok, a} | {:error, String.t()})) ::
          {:ok, a} | {:error, String.t()}
        when a: var
  def in_org(text, nil, _read),
    do: {:error, "#{text} names no org, and none is given; name it as org/#{text}"}

  def in_org(text, org, read) do
    case read.(org <> "/" <> text) do
      {:ok, _value} = ok -> ok
      {:error, _message} -> {:error, not_an_id(text)}
    end
  end

  defp from_segments([org, "@" <> user, name]), do: build(org, user, name)
  defp from_segments([org, name]), do: build(org, nil, name)
  defp from_segments(_segments), do: :error

  defp build(org, user, name) do
    if org?(org) and segment?(name) and (user == nil or segment?(user)),
      do: {:ok, %__MODULE__{org: org, user: user, name: name}},
      else: :error
  end

  @doc """
  An ID written in the code, read when it is compiled.

      ~A"acme/@jon/triage"
  """
  defmacro sigil_A({:<<>>, _meta, [text]}, []) when is_binary(text),
    do: Macro.escape(parse!(text))

  defp part(nil, what), do: {:error, "an agent's #{what} is missing"}
  defp part(value, what), do: written(Segment.to_segment(value), value, what)

  defp optional(nil, _what), do: {:ok, nil}
  defp optional(value, what), do: part(value, what)

  defp written("deployment", _value, "org"),
    do: {:error, "an agent's org is deployment, which names the deployment itself"}

  defp written(segment, value, what) do
    if segment?(segment),
      do: {:ok, segment},
      else:
        {:error,
         "an agent's #{what} is #{inspect(segment)} from #{inspect(value)}, which is not a " <>
           "segment; a segment holds no / or whitespace, nor *, ? or :, and does not begin " <>
           "with @ or _"}
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  defp not_an_id(text), do: "#{text} is not an agent ID; an ID is org/name or org/@user/name"

  defimpl String.Chars do
    def to_string(%{org: org, user: nil, name: name}), do: org <> "/" <> name
    def to_string(%{org: org, user: user, name: name}), do: "#{org}/@#{user}/#{name}"
  end

  defimpl Wardrik.AgentAddress do
    def resource(id), do: Wardrik.AgentID.resource(id)
    def agent(id), do: id
  end

  defimpl Inspect do
    def inspect(id, _opts), do: "~A\"" <> to_string(id) <> "\""
  end
end
