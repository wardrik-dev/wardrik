defmodule Wardrik.Principal do
  @moduledoc """
  Who did something, and how they were known: the person or system behind a
  decision.

      Wardrik.Principal.new(:channel, "slack/T0123/U024BE7LH", name: "jon")

  A principal is built here and read with `type/1`, `id/1` and `name/1`, and
  what it is made of is its own business: a surface that knows its callers
  another way, or knows more about them, changes nothing that reads one.

  `type/1` says how they reached Wardrik:

    * `:shell` - an operating system account on the node, through `bin/wardrik`
    * `:ssh` - an SSH session to the TUI, by the name the client connected as
    * `:terminal` - a TUI started in a terminal on the node
    * `:channel` - someone in a chat channel, by the channel's name, the
      workspace it is installed in, and the id the channel knows them by
      there, as `slack/T0123/U024BE7LH`; see `WardrikChannel.principal/3`
    * `:oauth` - an authorization flow that finished, by the provider it was
      for: whoever completed it is not known
    * `:token` - a caller of the HTTP API, by the id of the token it presented
    * `:agent` - an agent acting through its tools, on itself or on another
      agent, and an agent answering one that asked it something, by its ID;
      see `Wardrik.Catalog.Tools`
    * `:webhook` - a request from outside to one of an agent's triggers, by
      the trigger it was sent to, as `org/name//trigger`: whoever sent it is
      known only by the secret its signature was made with
    * `:user` - a person named where a credential was issued to them, as a
      token made for them, or known by a sign-in
  """

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :name]

  @typedoc "How a principal reached Wardrik."
  @type type() ::
          :shell
          | :ssh
          | :terminal
          | :channel
          | :oauth
          | :token
          | :webhook
          | :agent
          | :user
          | atom()

  @opaque t() :: %__MODULE__{type: type(), id: String.t(), name: String.t() | nil}

  @doc "A principal that reached Wardrik as `type`, known there as `id`, and by `name:` where they have one."
  @spec new(type(), String.t(), name: String.t() | nil) :: t()
  def new(type, id, opts \\ []) when is_atom(type) and is_binary(id) and is_list(opts),
    do: %__MODULE__{type: type, id: id, name: Keyword.get(opts, :name)}

  @doc "How the principal reached Wardrik."
  @spec type(t()) :: type()
  def type(%__MODULE__{type: type}), do: type

  @doc "What the principal is known as where they reached Wardrik."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}), do: id

  @doc "The name they go by, where one is known."
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{name: name}), do: name

  @doc """
  Whether `a` and `b` are the same person or system: reached the same way
  and known by the same id, whatever name each goes by. Nobody, `nil`, is
  never anyone.
  """
  @spec same?(t() | nil, t() | nil) :: boolean()
  def same?(%__MODULE__{type: type, id: id}, %__MODULE__{type: type, id: id}), do: true
  def same?(_a, _b), do: false
end
