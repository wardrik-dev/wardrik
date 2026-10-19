defmodule WardrikOAuth.Provider do
  @moduledoc """
  One thing a user can authorize Wardrik for, and what is known about it in
  advance.

      WardrikOAuth.new(
        providers: [
          github: [
            resource: "https://api.githubcopilot.com/mcp/",
            issuer: "https://github.com/login/oauth",
            client_id: System.get_env("GITHUB_CLIENT_ID"),
            client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
            scopes: ~w(repo read:org)
          ],
          linear: [resource: "https://mcp.linear.app/mcp"]
        ]
      )

  The name is a credential's: a credential named `github` that nobody holds
  is asked for through the `:github` provider. Everything but `:resource` is optional —
  `:client_id` is for a server that will not register a client any other way,
  and `:issuer` names the authorization server rather than taking the one the
  resource's metadata names, and trusts it and its endpoints as the
  deployment's own (see `WardrikOAuth.Egress`). A `:client_secret` is sent only
  to a named `:issuer`.

  `:authorization_params` are more to send with the authorization request
  in a browser, for a server that needs them. Google, for one, gives a
  token it can refresh only when asked with `access_type: "offline"`, and
  gives one again after the first time only with `prompt: "consent"`:

      authorization_params: %{"access_type" => "offline", "prompt" => "consent"}

  They cannot set what the flow sets itself, such as `redirect_uri` or
  `state` (see `WardrikOAuth.Flow.own_params/0`), and a provider whose
  params name one is refused.

  `:flow` is how the user authorizes:

    * `:browser` - in a browser sent back to this deployment's redirect URI,
      the authorization code flow
    * `:device` - by entering a code at the server's page, on any device, the
      device authorization grant; see `WardrikOAuth.Device`
    * `:auto`, the default - on another device where the server offers it and
      a browser sent back to this machine cannot be, because the redirect
      comes back to loopback and there is no browser here to open; in a
      browser otherwise

  `:trust` is whose word its `:resource` rests on, as `WardrikOAuth.Egress`
  holds a URL to: `:operator` for one the deployment configures, and
  `:discovered` for one added for an owner, `WardrikOAuth.Providers`.
  """

  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:name, :resource]
  defstruct [
    :name,
    :resource,
    :issuer,
    :client_id,
    :client_secret,
    scopes: [],
    authorization_params: %{},
    flow: :auto,
    trust: :operator
  ]

  @typedoc "A provider a user can authorize."
  @type t() :: %__MODULE__{
          name: String.t(),
          resource: String.t(),
          issuer: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scopes: [String.t()],
          authorization_params: %{optional(String.t()) => String.t()},
          flow: flow(),
          trust: WardrikOAuth.Egress.trust()
        }

  @typedoc """
  How a user authorizes: in a browser that is sent back here, by entering a
  code on any device, or whichever of the two suits this deployment.
  """
  @type flow() :: :auto | :browser | :device

  @doc "Builds a provider from its name and options."
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(name, opts) do
    opts =
      opts
      |> Keyword.update(:flow, :auto, &flow!/1)
      |> Keyword.update(:authorization_params, %{}, &authorization_params!/1)

    struct!(__MODULE__, Keyword.put(opts, :name, to_string(name)))
  end

  @doc """
  Reads a provider's authorization params into text, refusing any that would
  set what the flow sets itself.
  """
  @spec authorization_params!(Enumerable.t()) :: %{optional(String.t()) => String.t()}
  def authorization_params!(params) do
    params = Map.new(params, fn {name, value} -> {to_string(name), to_string(value)} end)

    case Enum.filter(Map.keys(params), &(&1 in WardrikOAuth.Flow.own_params())) do
      [] ->
        params

      own ->
        raise ArgumentError,
              IO.iodata_to_binary([
                "a provider's authorization_params cannot set ",
                Enum.intersperse(own, ", "),
                ", which the flow sets itself"
              ])
    end
  end

  @flows %{"auto" => :auto, "browser" => :browser, "device" => :device}

  @doc "Reads a flow, written as an atom or as text."
  @spec flow!(atom() | String.t()) :: flow()
  def flow!(flow) when flow in [:auto, :browser, :device], do: flow

  def flow!(flow) when is_binary(flow) do
    case Map.fetch(@flows, flow) do
      {:ok, flow} ->
        flow

      :error ->
        raise ArgumentError, "a provider's flow is auto, browser or device, not #{inspect(flow)}"
    end
  end

  def flow!(flow),
    do: raise(ArgumentError, "a provider's flow is auto, browser or device, not #{inspect(flow)}")

  @doc """
  The provider `name` is for `owner`: the one `oauth` configures under it,
  else one its `:added` holds for them.
  """
  @spec fetch(WardrikOAuth.t(), String.t(), WardrikVault.owner()) :: {:ok, t()} | :error
  def fetch(%WardrikOAuth{providers: providers, added: added}, name, owner)
      when is_binary(name) do
    Enum.find_value(providers, fn {configured, opts} ->
      if to_string(configured) == name, do: {:ok, new(configured, opts)}
    end) || WardrikOAuth.Providers.fetch(added, name, owner: owner)
  end

  @doc "Every provider `oauth` configures."
  @spec all(WardrikOAuth.t()) :: [t()]
  def all(%WardrikOAuth{providers: providers}),
    do: Enum.map(providers, fn {name, opts} -> new(name, opts) end)

  @doc """
  Every name a sign-in may come back for: those `oauth` configures, and
  those its `:added` holds for any owner.
  """
  @spec names(WardrikOAuth.t()) :: [String.t()]
  def names(%WardrikOAuth{added: added} = oauth),
    do: Enum.map(all(oauth), & &1.name) ++ WardrikOAuth.Providers.names(added)
end
