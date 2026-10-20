defmodule Wardrik.AgentID do
  @moduledoc """
  Which agent: the org it belongs to, the user it works for if it works for
  one, its name, and the external ID it answers for where one agent answers
  for many, such as a thread in a chat.

  An agent's ID is its address across the cluster and its topic on the event
  bus. It is built once, where a host or a person names an agent, and carried
  as this value from there on; its text is written only where something
  outside the BEAM needs it, such as an HTTP path or an event. A store key
  names the agent by its `resource/1`, which `from_resource/1` reads back.

  | Text | The agent |
  | --- | --- |
  | `acme/triage` | acme's own `triage` |
  | `acme/@jon/triage` | jon's `triage`, in acme |
  | `acme/triage/1696.1234` | acme's `triage`, answering for `1696.1234` |
  | `acme/@jon/triage/1696.1234` | the same, for jon |

      id = Wardrik.AgentID.new!("researcher", org: current_org, user: current_user)
      Wardrik.Fleet.spawn(id, config: config)

  `new/2` writes the host's own org and user values down through
  `Wardrik.AgentID.Segment`. A segment is the org, the user, the name or the
  external ID. It holds no `/` or whitespace, nor `*` or `?`, which patterns
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
  defstruct [:org, :user, :name, :external_id]

  @type t() :: %__MODULE__{
          org: String.t(),
          user: String.t() | nil,
          name: String.t(),
          external_id: String.t() | nil
        }

  @segment ~r/\A[^\/:@_\s*?][^\/:\s*?]*\z/u

  @doc """
  The ID of the agent named `name` in `:org`, working for `:user` and
  answering for `:external_id` where either is given. Each is written down
  through `Wardrik.AgentID.Segment`.
  """
  @spec new(term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(name, opts) when is_list(opts) do
    with {:ok, org} <- part(Keyword.get(opts, :org), "org"),
         {:ok, name} <- part(name, "name"),
         {:ok, user} <- optional(Keyword.get(opts, :user), "user"),
         {:ok, external_id} <- optional(Keyword.get(opts, :external_id), "external ID") do
      {:ok, %__MODULE__{org: org, user: user, name: name, external_id: external_id}}
    end
  end

  @doc "`new/2`, raising `ArgumentError` where it answers an error."
  @spec new!(term(), keyword()) :: t()
  def new!(name, opts), do: ok!(new(name, opts))

  @doc """
  `id` answering for `external_id`, written down through
  `Wardrik.AgentID.Segment`, or for none where it is `nil`: the agent whose
  definition every external ID of it runs on.
  """
  @spec put_external_id(t(), term()) :: t()
  def put_external_id(%__MODULE__{} = id, nil), do: %{id | external_id: nil}

  def put_external_id(%__MODULE__{} = id, external_id),
    do: %{id | external_id: ok!(part(external_id, "external ID"))}

  @doc "Whether `text` can be one segment of an ID: an org, a user, a name or an external ID."
  @spec segment?(term()) :: boolean()
  def segment?(text) when is_binary(text),
    do: text not in [".", ".."] and Regex.match?(@segment, text)

  def segment?(_text), do: false

  @doc "Whether `text` can be an org: a segment other than `deployment`."
  @spec org?(term()) :: boolean()
  def org?(text), do: segment?(text) and text != "deployment"

  @doc """
  The resource `id` names, as a `Wardrik.Statement` names it.

      Wardrik.AgentID.resource(~A"acme/@jon/triage/1696.1234")
      #=> #Wardrik.Resource<acme/@jon/agent/triage/thread/1696.1234>
  """
  @spec resource(t()) :: Resource.t()
  def resource(%__MODULE__{org: org, user: user, name: name, external_id: external_id}) do
    owner = if user, do: [org, "@" <> user], else: [org]
    thread = if external_id, do: ["thread", external_id], else: []
    %Resource{name: Enum.join(owner ++ ["agent", name] ++ thread, "/")}
  end

  @doc """
  The agent `resource` names, as `resource/1` names it, or `:error` where it
  names none.

      Wardrik.AgentID.from_resource(Wardrik.Resource.parse!("acme/@jon/agent/triage"))
      #=> {:ok, ~A"acme/@jon/triage"}
  """
  @spec from_resource(Resource.t()) :: {:ok, t()} | :error
  def from_resource(%Resource{name: name}) do
    case String.split(name, "/") do
      [org, "@" <> _name = user | agent] -> agent([org, user], agent)
      [org | agent] -> agent([org], agent)
    end
  end

  defp agent(owner, ["agent", name]), do: from_segments(owner ++ [name])

  defp agent(owner, ["agent", name, "thread", external_id]),
    do: from_segments(owner ++ [name, external_id])

  defp agent(_owner, _other), do: :error

  @doc """
  The ID `text` writes, as `to_string/1` writes one.

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
  The ID `text` names, where an agent in `org` may be named without it: an
  org's own agent by its name, and a user's as `@user/name`. With `org` `nil`,
  `text` has to name its org.

      Wardrik.AgentID.expand("triage", "app")            #=> {:ok, ~A"app/triage"}
      Wardrik.AgentID.expand("@jon/triage", "app")       #=> {:ok, ~A"app/@jon/triage"}
      Wardrik.AgentID.expand("acme/@jon/triage", "app")  #=> {:ok, ~A"acme/@jon/triage"}
  """
  @spec expand(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def expand(text, org) when is_binary(text) do
    case String.split(text, "/") do
      [_name] -> in_org(text, org, &parse/1)
      ["@" <> _user, _name] -> in_org(text, org, &parse/1)
      _whole -> parse(text)
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

  @doc false
  @spec segments(t()) :: [String.t()]
  def segments(%__MODULE__{org: org, user: user, name: name, external_id: external_id}) do
    [org] ++
      if(user, do: ["@" <> user], else: []) ++
      [name] ++ if(external_id, do: [external_id], else: [])
  end

  @doc false
  @spec from_segments([String.t()]) :: {:ok, t()} | :error
  def from_segments([org, "@" <> user, name, external]), do: build(org, user, name, external)
  def from_segments([org, "@" <> user, name]), do: build(org, user, name, nil)
  def from_segments([org, name, external]), do: build(org, nil, name, external)
  def from_segments([org, name]), do: build(org, nil, name, nil)
  def from_segments(_segments), do: :error

  defp build(org, user, name, external_id) do
    if org?(org) and Enum.all?(Enum.reject([user, name, external_id], &is_nil/1), &segment?/1),
      do: {:ok, %__MODULE__{org: org, user: user, name: name, external_id: external_id}},
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

  defp not_an_id(text),
    do:
      "#{text} is not an agent ID; an ID is org/name or org/@user/name, " <>
        "with an external ID after it where it answers for one"

  defimpl String.Chars do
    def to_string(id), do: id |> Wardrik.AgentID.segments() |> Enum.join("/")
  end

  defimpl Inspect do
    def inspect(id, _opts), do: "~A\"" <> to_string(id) <> "\""
  end
end
