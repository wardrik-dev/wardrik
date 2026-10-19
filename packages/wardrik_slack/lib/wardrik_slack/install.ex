defmodule WardrikSlack.Install do
  @moduledoc """
  Installing a channel's app in a workspace, as Slack's OAuth has it: the
  channel's `client_id` and `client_secret` send someone to add the app to
  a workspace of theirs, and Slack sends them back to the app's Redirect
  URL, under **OAuth & Permissions**, with a code that is exchanged for
  the workspace's bot token.

  Where they are sent carries, signed with the client secret, the owner it
  was asked for, where to go once it is installed, and when it expires,
  ten minutes on. Coming back, the host hands it over as someone acting for
  an owner, and the app is installed for them only where it was asked for
  that owner: so a link someone else started cannot install a workspace
  for them. The installation is kept with the context's
  `WardrikChannel.Installations`, which may refuse it.
  """

  alias Wardrik.Resource
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Request
  alias WardrikChannel.Response

  @authorize "https://slack.com/oauth/v2/authorize"

  # What the app does: read and post in the Slack channels it is invited
  # into, mark the messages it answers, and find people by handle or email.
  @scopes ~w(channels:history channels:read chat:write groups:history groups:read
             reactions:write users:read users:read.email)

  # How long, in seconds, an install may take.
  @expires 600

  @doc "The bot scopes the app asks for as it is installed."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Where someone acting for `owner` is sent to install the app, given the channel's options."
  @spec url(Resource.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def url(owner, opts) do
    with {:ok, id, secret} <- client(opts) do
      state =
        sign(
          %{
            "o" => to_string(owner),
            "r" => opts[:return_to],
            "e" => System.os_time(:second) + @expires
          },
          secret
        )

      query = URI.encode_query(client_id: id, scope: Enum.join(@scopes, ","), state: state)
      {:ok, @authorize <> "?" <> query}
    end
  end

  @doc """
  Answers Slack sending someone acting for `owner` back from installing the
  app, given the channel's options.
  """
  @spec installed(Resource.t(), Request.t(), keyword()) :: Response.t()
  def installed(owner, %Request{query: query}, opts) do
    with {:ok, id, secret} <- client(opts),
         {:ok, state} <- verified(query["state"], secret, owner),
         {:ok, code} <- code(query),
         {:ok, installation} <- exchange(code, {id, secret}, owner, opts),
         :ok <- Installations.put(Keyword.fetch!(opts, :context).installations, installation) do
      done(installation, state["r"])
    else
      {:error, status, message} -> Response.text(status, message)
      {:error, message} -> Response.text(409, message)
    end
  end

  defp client(opts) do
    case {opts[:client_id], opts[:client_secret]} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        {:ok, id, secret}

      _unnamed ->
        {:error, 404,
         "#{opts[:name]} is installed from its token only; installing it in more " <>
           "workspaces needs its client_id and client_secret."}
    end
  end

  defp code(%{"code" => code}) when is_binary(code), do: {:ok, code}

  defp code(%{"error" => error}),
    do: {:error, 400, "Slack did not add the app: #{error}. Start again to add it."}

  defp code(_query), do: {:error, 400, "Slack sent no code back. Start again to add the app."}

  defp exchange(code, {id, secret}, owner, opts) do
    case WardrikSlack.call(
           "oauth.v2.access",
           [form: [client_id: id, client_secret: secret, code: code]] ++
             Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %{"access_token" => token, "team" => %{"id" => team}} = access} ->
        installation = %Installation{
          channel: Keyword.fetch!(opts, :name),
          workspace: team,
          owner: owner,
          token: token
        }

        if bot = access["bot_user_id"],
          do: :persistent_term.put({WardrikSlack, :bot, installation.channel, team}, bot)

        {:ok, installation}

      {:error, reason} ->
        {:error, 502, "Slack did not give the app its token: #{inspect(reason)}. Start again."}
    end
  end

  defp done(_installation, return_to) when is_binary(return_to), do: Response.redirect(return_to)

  defp done(%Installation{channel: channel}, nil),
    do: Response.text(200, "#{channel} is added to your Slack workspace. You can close this.")

  defp sign(state, secret) do
    payload = state |> JSON.encode!() |> Base.url_encode64(padding: false)
    payload <> "." <> mac(payload, secret)
  end

  defp verified(text, secret, owner) when is_binary(text) do
    with [payload, mac] <- String.split(text, ".", parts: 2),
         true <- same?(mac, mac(payload, secret)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"o" => for_owner, "e" => expires} = state} <- JSON.decode(json),
         true <- for_owner == to_string(owner),
         true <- System.os_time(:second) <= expires do
      {:ok, state}
    else
      _unverified -> refused()
    end
  end

  defp verified(_none, _secret, _owner), do: refused()

  defp refused,
    do:
      {:error, 403,
       "This install was started by someone else, or for another org, or too long ago. " <>
         "Start it again from where you add Slack."}

  defp same?(given, expected),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)

  defp mac(payload, secret),
    do: :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.url_encode64(padding: false)
end
