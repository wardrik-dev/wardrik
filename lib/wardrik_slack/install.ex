defmodule WardrikSlack.Install do
  @moduledoc """
  Adds one Slack app to many workspaces.

      slack:
        {WardrikSlack,
         client_id: "...",
         client_secret: "...",
         redirect_uri: "https://app.example.com/slack/installed",
         signing_secret: "...",
         installations: :stored,
         identities: {MyApp.ChatMembers, []}}

  Set the app's **Redirect URL**, under **OAuth & Permissions**, to `:redirect_uri`. Tokens are
  sealed with Wardrik's `:keys`.

      # 1. Send someone to Slack
      {:ok, url} =
        Wardrik.Channels.install_url(MyApp.AgentRuntime,
          channel: "slack",
          owner: "acme",
          return_to: "/settings"
        )

      # 2. In your :redirect_uri route
      installed =
        Wardrik.Channels.installed(MyApp.AgentRuntime,
          channel: "slack",
          owner: "acme",
          query: conn.query_params
        )

      case installed do
        {:ok, _installation, return_to} -> redirect(conn, external: return_to || "/")
        {:error, message} -> send_resp(conn, 400, message)
      end

  The URL lasts ten minutes, and only adds a workspace for the owner it was made for.
  """

  alias Wardrik.Channel.Installation
  alias WardrikChannel.Channel
  alias WardrikSlack.API

  @authorize "https://slack.com/oauth/v2/authorize"
  @scopes ~w(channels:history channels:read chat:write chat:write.public groups:history
             groups:read reactions:write users:read)
  @expires 600

  @doc "Returns the bot scopes the app asks for."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Returns the Slack URL where someone adds the app for `owner`.

  ## Options

    * `:return_to` - where to send them once it's added. Returned by `installed/3`.
  """
  @spec url(Channel.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def url(channel, owner, opts \\ []) do
    with {:ok, id, secret} <- client(channel) do
      state =
        sign(
          %{"o" => owner, "r" => opts[:return_to], "e" => System.os_time(:second) + @expires},
          secret
        )

      query =
        [
          client_id: id,
          scope: Enum.join(@scopes, ","),
          state: state,
          redirect_uri: channel.options[:redirect_uri]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> URI.encode_query()

      {:ok, @authorize <> "?" <> query}
    end
  end

  @doc """
  Adds the app to a workspace for `owner`, from the `query` Slack redirects back with.

  Returns the installation and the `:return_to` given to `url/3`, or `{:error, message}`.
  """
  @spec installed(Channel.t(), String.t(), map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def installed(channel, owner, query) do
    with {:ok, id, secret} <- client(channel),
         {:ok, state} <- verified(query["state"], secret, owner),
         {:ok, code} <- code(query),
         {:ok, installation} <- exchange(channel, code, {id, secret}, owner),
         :ok <- Channel.install(channel, installation) do
      {:ok, installation, state["r"]}
    end
  end

  defp client(%Channel{name: name, options: options}) do
    case {options[:client_id], options[:client_secret]} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        {:ok, id, secret}

      _unnamed ->
        {:error,
         "#{name} is added with its token alone. Give it client_id and client_secret to add it to more workspaces."}
    end
  end

  defp code(%{"code" => code}) when is_binary(code), do: {:ok, code}

  defp code(%{"error" => error}),
    do: {:error, "Slack didn't add the app: #{error}. Start again to add it."}

  defp code(_query), do: {:error, "Slack sent no code back. Start again to add the app."}

  defp exchange(channel, code, {id, secret}, owner) do
    form =
      Enum.reject(
        [
          client_id: id,
          client_secret: secret,
          code: code,
          redirect_uri: channel.options[:redirect_uri]
        ],
        fn {_key, value} -> is_nil(value) end
      )

    case API.call("oauth.v2.access", [form: form] ++ API.req_options(channel)) do
      {:ok, %{"access_token" => token, "team" => %{"id" => team} = workspace}} ->
        {:ok,
         %Installation{
           channel: channel.name,
           workspace: team,
           name: workspace["name"],
           owner: owner,
           token: token
         }}

      {:error, reason} ->
        {:error,
         "Slack didn't give the app its token (#{inspect(reason)}). Start again to add it."}
    end
  end

  defp sign(state, secret) do
    payload = state |> JSON.encode!() |> Base.url_encode64(padding: false)
    payload <> "." <> mac(payload, secret)
  end

  defp verified(text, secret, owner) when is_binary(text) do
    with [payload, mac] <- String.split(text, ".", parts: 2),
         true <- same?(mac, mac(payload, secret)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"o" => ^owner, "e" => expires} = state} <- JSON.decode(json),
         true <- System.os_time(:second) <= expires do
      {:ok, state}
    else
      _unverified -> refused()
    end
  end

  defp verified(_none, _secret, _owner), do: refused()

  defp refused,
    do:
      {:error,
       "This was started by someone else, for another org, or too long ago. Start again to add the app."}

  defp same?(given, expected),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp mac(payload, secret),
    do: :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.url_encode64(padding: false)
end
