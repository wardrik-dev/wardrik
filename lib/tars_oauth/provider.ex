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
  """

  @enforce_keys [:name, :resource]
  defstruct [
    :name,
    :resource,
    :issuer,
    :client_id,
    :client_secret,
    :redirect_uri,
    scopes: []
  ]

  @typedoc "A provider a user can authorize."
  @type t() :: %__MODULE__{
          name: String.t(),
          resource: String.t(),
          issuer: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          redirect_uri: String.t() | nil,
          scopes: [String.t()]
        }

  @doc "Builds a provider from its name and options."
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(name, opts) do
    struct!(__MODULE__, Keyword.put(opts, :name, to_string(name)))
  end

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
