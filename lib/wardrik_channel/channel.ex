defmodule WardrikChannel.Channel do
  @moduledoc """
  One chat app Wardrik runs, under the name it's configured with. Adapters get it from
  `WardrikChannel.channel/2`. See `WardrikChannel` for its options.

    * `:options` - the options left over for the adapter, such as Slack's `:signing_secret`.
    * `:vault` - where tokens are sealed. `nil` without Wardrik's `:vault_keys`.
  """

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Installations.Request
  alias WardrikChannel.Identities
  alias WardrikChannel.Installations.Stored
  alias WardrikChannel.Installations.Token

  @options [
    token: [
      type: {:or, [:string, nil]},
      doc: "The token the channel acts with, in the one workspace it reaches. Needs `:owner`."
    ],
    owner: [
      type: :string,
      doc: "Who added it, as your app names them. Your authorizer reads it. Needs `:token`."
    ],
    installations: [
      type: {:or, [{:in, [:stored]}, {:tuple, [:atom, :any]}]},
      doc: """
      Instead of `:token`, to add one app to many workspaces. `:stored` keeps them in Wardrik,
      which needs Wardrik's `:vault_keys`. `{module, config}` names a
      `Wardrik.Channel.Installations`.
      """
    ],
    identities: [
      type: :mod_arg,
      required: true,
      doc: """
      The `WardrikChannel.Identities` that says who each member is in your app, as
      `{module, opts}`. A member it doesn't know can't ask or decide.
      """
    ],
    offering: [type: :string, doc: "What a room with no agent is told."],
    deciding: [type: :string, doc: "What a member who may not decide is told."],
    server: [type: :atom, required: true, doc: false],
    wardrik: [type: :atom, required: true, doc: false],
    events: [type: :atom, required: true, doc: false],
    vault: [type: {:or, [:atom, nil]}, default: nil, doc: false],
    channel: [type: :string, required: true, doc: false],
    store: [type: :any, required: true, doc: false]
  ]

  @schema NimbleOptions.new!(@options)

  @enforce_keys [
    :name,
    :server,
    :wardrik,
    :events,
    :adapter,
    :store,
    :installations,
    :identities,
    :offering,
    :deciding,
    :options
  ]
  defstruct [vault: nil] ++ @enforce_keys

  @type t() :: %__MODULE__{
          name: String.t(),
          server: module(),
          wardrik: atom(),
          events: atom(),
          vault: atom() | nil,
          adapter: module(),
          store: WardrikStore.t(),
          installations: {module(), term()},
          identities: {module(), term()},
          offering: String.t(),
          deciding: String.t(),
          options: keyword()
        }

  @doc """
  Builds `adapter`'s channel from the options Wardrik passes it.

  Raises `NimbleOptions.ValidationError` on an invalid option, or `ArgumentError` on a bad name
  or without exactly one of `:token` and `:installations`.
  """
  @spec new(module(), keyword()) :: t()
  def new(adapter, opts) do
    {own, options} = Keyword.split(opts, Keyword.keys(@options))
    own = NimbleOptions.validate!(own, @schema)
    name = Keyword.fetch!(own, :channel)
    named!(name)
    installations = installations!(name, own)
    vault = own[:vault]
    store = WardrikStore.scope(own[:store], "wardrik_channel")

    %__MODULE__{
      name: name,
      server: own[:server],
      wardrik: own[:wardrik],
      events: own[:events],
      vault: vault,
      adapter: adapter,
      store: store,
      installations: stored(installations, vault, store),
      identities: own[:identities],
      offering: Keyword.get(own, :offering, offering(name)),
      deciding: Keyword.get(own, :deciding, deciding()),
      options: options
    }
  end

  @doc false
  def schema, do: @schema

  @doc "Returns the channel's installation in `workspace`, as the chat app names it."
  @spec installation(t(), String.t()) :: {:ok, Installation.t()} | :error
  def installation(%__MODULE__{name: name, installations: {module, config}}, workspace),
    do: module.fetch(%Request{channel: name, workspace: workspace}, config)

  @doc """
  Returns the channel's installations whose owner is exactly `owner`.

      WardrikChannel.Channel.owned(channel, "acme")
      #=> [%Wardrik.Channel.Installation{workspace: "T0123", owner: "acme", ...}]
  """
  @spec owned(t(), String.t()) :: [Installation.t()]
  def owned(%__MODULE__{name: name, installations: {module, config}}, owner),
    do: module.owned(%Request{channel: name, owner: owner}, config)

  @doc "Returns who `member` of `workspace` is in your app, or what to tell them if unknown."
  @spec identify(t(), String.t(), WardrikChannel.Member.t()) ::
          {:ok, WardrikCore.Principal.t()} | {:error, String.t()}
  def identify(%__MODULE__{name: name, identities: {module, config}}, workspace, member) do
    request = %Identities.Request{
      channel: name,
      workspace: workspace,
      member: member.id,
      name: member.name
    }

    case module.identify(request, config) do
      {:ok, %WardrikCore.Principal{} = principal} -> {:ok, principal}
      {:error, why} when is_binary(why) -> {:error, why}
      _unknown -> {:error, "You aren't known to #{name} here, so you can't act through it."}
    end
  end

  @doc "Saves `installation`, replacing any for the same workspace."
  @spec install(t(), Installation.t()) :: :ok | {:error, String.t()}
  def install(%__MODULE__{installations: {module, config}}, installation),
    do: module.put(installation, config)

  @doc "Forgets the channel's installation in `workspace`."
  @spec uninstall(t(), String.t()) :: :ok
  def uninstall(%__MODULE__{name: name, installations: {module, config}}, workspace),
    do: module.delete(%Request{channel: name, workspace: workspace}, config)

  defp named!(name) do
    if not Regex.match?(~r/^[a-z][a-z0-9-]*$/, name),
      do:
        raise(
          ArgumentError,
          "A channel's name is lower-case letters, digits and -, starting with a letter. " <>
            "#{inspect(name)} isn't."
        )
  end

  defp installations!(name, opts) do
    case Keyword.take(opts, [:installations, :token]) do
      [installations: :stored] ->
        :stored

      [installations: {module, _config} = installations] when is_atom(module) ->
        installations

      [token: _token] ->
        {Token, Keyword.take(opts, [:token, :owner])}

      _neither_or_both ->
        raise ArgumentError,
              "Give the channel #{name} a token: and an owner:, or its installations:."
    end
  end

  defp stored(:stored, vault, store), do: {Stored, vault: vault, store: store}
  defp stored(installations, _vault, _store), do: installations

  defp offering(name),
    do: "An agent answers here once its definition lists #{name} among its channels."

  defp deciding,
    do: "You may not decide what this agent waits on."
end
