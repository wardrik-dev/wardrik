defmodule WardrikSlack.Test do
  @moduledoc """
  Runs a Slack channel for a test, on the test's own server over a real store and events, in front
  of a fake Slack that sends the test each call it takes, as `{:slack, method, params}`.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @people %{"U1" => "maria", "U2" => "jon", "U3" => "ana"}

  alias WardrikTesting.Server

  def start_slack(context) do
    n = System.unique_integer([:positive])
    name = :"wardrik #{n}"
    store = WardrikStore.ETS.new(name: :"store #{n}")
    events = Server.events(name)
    vault = :"vault #{n}"
    test = self()

    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(WardrikSlack.Test.Slack, &slack(&1, test))

    slack =
      [
        token: "xoxb-test",
        signing_secret: "s3cret",
        owner: "acme",
        identities: {WardrikSlack.Test.Members, members: @people},
        req_options: [plug: {Req.Test, WardrikSlack.Test.Slack}, retry_delay: 0]
      ]
      |> Keyword.merge(Map.get(context, :slack, []))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    options =
      slack ++
        [
          server: Server,
          wardrik: name,
          events: events,
          vault: vault,
          channel: "slack",
          store: store
        ]

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {WardrikEvents, name: events, store: store, deployment: "test", retention: :infinity}
    )

    start_supervised!(
      {WardrikVault, name: vault, store: store, keys: [WardrikVault.generate_key()]}
    )

    :ok = Server.start(name, authorize: &deciders/1)
    start_supervised!(WardrikSlack.child_spec(options))

    owner = Wardrik.Scope.new(Server, wardrik: name, principal: "acme/@maria")

    channel = WardrikChannel.channel(WardrikSlack, options)

    %{wardrik: name, owner: owner, channel: channel, options: options, events: events}
  end

  @doc """
  Allows everything but deciding, which only maria, whose binding allows it, or whoever asked may
  do, as your app's authorizer might.
  """
  def deciders(%{operation: "agent." <> verb, scope: %{context: context} = scope})
      when verb in ["approve", "deny"] do
    if scope.principal.id == "maria" or context[:asked_by] == scope.principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  def deciders(_request), do: :ok

  def define(owner, id, fields \\ []),
    do:
      Server.add_agent(owner.wardrik,
        id: id,
        channels: fields[:channels] || [],
        description: fields[:description]
      )

  @doc "Sends Slack's signed request to the channel, and returns its answer."
  def deliver(context, path, body, opts \\ []) do
    at = Keyword.get(opts, :at, System.os_time(:second))
    secret = Keyword.get(opts, :secret, "s3cret")

    headers = %{
      "x-slack-request-timestamp" => Integer.to_string(at),
      "x-slack-signature" => WardrikSlack.HTTP.signature(secret, at, body)
    }

    WardrikSlack.request(%{path: path, body: body, headers: headers}, context.options)
  end

  def event(context, event),
    do:
      deliver(
        context,
        "events",
        JSON.encode!(%{
          type: "event_callback",
          team_id: "T1",
          authorizations: [%{user_id: "UBOT"}],
          event: event
        })
      )

  def press(context, payload),
    do:
      deliver(
        context,
        "actions",
        URI.encode_query(%{payload: JSON.encode!(Map.put_new(payload, :team, %{id: "T1"}))})
      )

  def message(text, ts, opts \\ []) do
    Map.merge(
      %{
        type: "message",
        channel: "C1",
        channel_type: "channel",
        user: Keyword.get(opts, :user, "U3"),
        text: text,
        ts: ts
      },
      Map.new(Keyword.delete(opts, :user))
    )
  end

  defp slack(conn, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = params(conn, body)
    method = method(conn)
    send(test, {:slack, method, params})
    Req.Test.json(conn, reply(method, params))
  end

  defp method(%Plug.Conn{host: "slack.com", path_info: ["api", method]}), do: method
  defp method(%Plug.Conn{request_path: path}), do: {:respond, path}

  defp params(conn, body) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      ["application/json" <> _rest] -> JSON.decode!(body)
      _form -> URI.decode_query(body)
    end
  end

  defp reply("users.info", %{"user" => id}) do
    name = Map.get(@people, id, "someone")

    %{
      ok: true,
      user: %{id: id, name: name, profile: %{display_name: name}}
    }
  end

  defp reply("chat.postMessage", _params), do: %{ok: true, ts: "9.9"}

  defp reply("apps.connections.open", _params), do: %{ok: false, error: "invalid_auth"}
  defp reply("auth.test", _params), do: %{ok: true, user: "wardrik", team: "Acme"}

  defp reply("oauth.v2.access", %{"code" => "good"}),
    do: %{
      ok: true,
      access_token: "xoxb-globex",
      team: %{id: "T7", name: "Globex"},
      bot_user_id: "UBOT"
    }

  defp reply("oauth.v2.access", _params), do: %{ok: false, error: "invalid_code"}
  defp reply(_method, _params), do: %{ok: true}
end

defmodule WardrikSlack.Test.Members do
  @moduledoc "Knows the Slack members of `:members` as their users, as your app's identities would."

  @behaviour WardrikChannel.Identities

  @impl WardrikChannel.Identities
  def identify(%WardrikChannel.Identities.Request{member: member}, opts) do
    case Map.fetch(Keyword.fetch!(opts, :members), member) do
      {:ok, user} -> {:ok, %WardrikCore.Principal{id: user}}
      :error -> {:error, "Nobody here knows you yet."}
    end
  end
end
