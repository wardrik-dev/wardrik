defmodule TarsOAuth.Provider do
  @moduledoc """
  One thing a user can authorize Tars for, and what is known about it in
  advance.

      config :tars, TarsOAuth,
        providers: [
          github: [
            resource: "https://api.githubcopilot.com/mcp/",
            client_id: System.get_env("GITHUB_CLIENT_ID"),
            client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
            scopes: ~w(repo read:org)
          ],
          linear: [resource: "https://mcp.linear.app/mcp"]
        ]

  The name is what a credential reference names: `{:user, "github"}` resolves
  through the `:github` provider. Everything but `:resource` is optional —
  `:client_id` is for a server that will not register a client any other way,
  and `:issuer` skips discovery for one that publishes no metadata.

  `:flow` is how the user authorizes:

    * `:browser` - in a browser sent back to this deployment's redirect URI,
      the authorization code flow
    * `:device` - by entering a code at the server's page, on any device, the
      device authorization grant; see `TarsOAuth.Device`
    * `:auto`, the default - on another device where the server offers it and
      a browser sent back to this machine cannot be, because the redirect
      comes back to loopback and there is no browser here to open; in a
      browser otherwise
  """

  @enforce_keys [:name, :resource]
  defstruct [
    :name,
    :resource,
    :issuer,
    :client_id,
    :client_secret,
    :redirect_uri,
    scopes: [],
    flow: :auto
  ]

  @typedoc "A provider a user can authorize."
  @type t() :: %__MODULE__{
          name: String.t(),
          resource: String.t(),
          issuer: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          redirect_uri: String.t() | nil,
          scopes: [String.t()],
          flow: flow()
        }

  @typedoc """
  How a user authorizes: in a browser that is sent back here, by entering a
  code on any device, or whichever of the two suits this deployment.
  """
  @type flow() :: :auto | :browser | :device

  @doc "Builds a provider from its name and options."
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(name, opts) do
    opts = Keyword.update(opts, :flow, :auto, &flow!/1)
    struct!(__MODULE__, Keyword.put(opts, :name, to_string(name)))
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

  @doc "The provider configured under `name`, if there is one."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name) do
    Enum.find_value(configured(), :error, fn {configured, opts} ->
      if to_string(configured) == name, do: {:ok, new(configured, opts)}
    end)
  end

  @doc "Every provider this deployment configured."
  @spec all() :: [t()]
  def all, do: Enum.map(configured(), fn {name, opts} -> new(name, opts) end)

  defp configured, do: TarsOAuth.Config.providers()
end
