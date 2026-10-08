defmodule WardrikOAuth.Client do
  @moduledoc """
  What Wardrik looks like to an authorization server: one identity, rendered
  however each server wants to be told about it.

      {WardrikOAuth.Supervisor,
       client: [
         name: "Wardrik",
         client_uri: "https://wardrik.dev",
         logo_uri: "https://wardrik.dev/logo.png",
         document_url: "https://wardrik.dev/oauth/client"
       ]}

  The same fields are the CIMD document a server fetches, the body of a dynamic
  registration, and what a person types into a provider's form. Branding is one
  artifact with three renderings rather than an app registration per platform.

  | Field | What it is |
  | --- | --- |
  | `:name` | the name on the consent screen |
  | `:client_uri`, `:logo_uri`, `:policy_uri`, `:tos_uri` | the rest of what a consent screen shows |
  | `:document_url` | where the CIMD document is served, which is also the `client_id` under CIMD |
  | `:redirect_uri` | where a code comes back to |
  | `:req_options` | merged into every request, which is how a test answers without a socket |
  """

  defstruct [
    :client_uri,
    :logo_uri,
    :policy_uri,
    :tos_uri,
    :document_url,
    :redirect_uri,
    name: "Wardrik",
    software_id: "wardrik",
    req_options: []
  ]

  @typedoc "The one client identity this deployment presents."
  @type t() :: %__MODULE__{
          name: String.t(),
          client_uri: String.t() | nil,
          logo_uri: String.t() | nil,
          policy_uri: String.t() | nil,
          tos_uri: String.t() | nil,
          document_url: String.t() | nil,
          redirect_uri: String.t() | nil,
          software_id: String.t(),
          req_options: keyword()
        }

  @doc "Builds the client from the `:client` setting, see `WardrikOAuth.Config`, with overrides."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, Keyword.merge(configured(), opts))
  end

  @doc """
  The metadata document, as JSON-ready data.

  Serve this at `:document_url` and that URL is a `client_id` any server
  supporting Client ID Metadata Documents will accept, with no registration
  anywhere.
  """
  @spec document(t()) :: map()
  def document(%__MODULE__{} = client) do
    %{
      "client_id" => client.document_url,
      "client_name" => client.name,
      "software_id" => client.software_id,
      "redirect_uris" => List.wrap(client.redirect_uri),
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
    |> put_present("client_uri", client.client_uri)
    |> put_present("logo_uri", client.logo_uri)
    |> put_present("policy_uri", client.policy_uri)
    |> put_present("tos_uri", client.tos_uri)
  end

  @doc "The same fields as a dynamic client registration body."
  @spec registration(t()) :: map()
  def registration(%__MODULE__{} = client) do
    client |> document() |> Map.delete("client_id")
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp configured, do: WardrikOAuth.Config.client()
end
