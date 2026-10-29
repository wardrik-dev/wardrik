defmodule Wardrik.Test.Slack.Tools do
  @moduledoc "A capability with one tool, `echo`."
  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      )
    ]
  end
end

defmodule Wardrik.Test.Slack do
  @moduledoc """
  Starts a Wardrik with a Slack channel for a test, in front of a fake Slack that sends the test
  each call it takes, as `{:slack, method, params}`.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @model "anthropic:claude-haiku-4-5"
  @people %{"U1" => "maria", "U2" => "jon", "U3" => "ana"}

  def start_wardrik(context) do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"
    test = self()

    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(WardrikSlack.Test.Slack, &slack(&1, test))

    slack =
      [
        token: "xoxb-test",
        signing_secret: "s3cret",
        owner: "acme",
        approvers: ["@maria"],
        req_options: [plug: {Req.Test, WardrikSlack.Test.Slack}, retry_delay: 0]
      ]
      |> Keyword.merge(Map.get(context, :slack, []))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         name: name,
         store: store,
         keys: [WardrikVault.generate_key()],
         channels: [slack: {WardrikSlack, slack}],
         capabilities: [tools: Wardrik.Test.Slack.Tools],
         policies: [careful: [ask: ["echo"]]],
         notify: Map.get(context, :notify),
         defaults: %{"retries" => %{"attempts" => 0, "on_exhausted" => "fail"}}
       )}
    )

    owner = Wardrik.as(name, "acme/@maria", roles: [:owner], resources: ["*"])

    {:ok, channel} = Wardrik.Test.Channel.fetch(name, "slack")

    %{wardrik: name, owner: owner, channel: channel}
  end

  def define(owner, id, fields \\ []) do
    {:ok, _agent} = Wardrik.Agent.define(owner, id, [model: @model] ++ fields)
    :ok
  end

  @doc "Sends Slack's signed request to the channel, through the Wardrik, and returns the answer."
  def deliver(context, path, body, opts \\ []) do
    at = Keyword.get(opts, :at, System.os_time(:second))
    secret = Keyword.get(opts, :secret, "s3cret")

    headers = %{
      "x-slack-request-timestamp" => Integer.to_string(at),
      "x-slack-signature" => WardrikSlack.HTTP.signature(secret, at, body)
    }

    scope = Wardrik.as(context.wardrik, "anonymous")

    {:ok, answer} =
      Wardrik.Channel.deliver(scope, Keyword.get(opts, :channel, "slack"), path,
        body: body,
        headers: headers
      )

    answer
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

  def answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  def answer(text), do: response(ReqLLM.Context.assistant(text))

  def calling(id, name, args),
    do:
      response(
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new(id, name, JSON.encode!(args))]
        )
      )

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}

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
      user: %{id: id, name: name, profile: %{display_name: name, email: "#{name}@example.com"}}
    }
  end

  defp reply("chat.postMessage", %{"channel" => "U4"}), do: %{ok: false, error: "cannot_dm_bot"}
  defp reply("chat.postMessage", _params), do: %{ok: true, ts: "9.9"}

  defp reply("users.list", %{"cursor" => "page-2"}),
    do: %{ok: true, members: [%{id: "U4", name: "bot"}], response_metadata: %{next_cursor: ""}}

  defp reply("users.list", _params) do
    members = Enum.map(@people, fn {id, name} -> %{id: id, name: name} end)

    %{
      ok: true,
      members: [%{id: "U0", name: "gone", deleted: true} | members],
      response_metadata: %{next_cursor: "page-2"}
    }
  end

  defp reply("users.lookupByEmail", %{"email" => email}) do
    case Enum.find(@people, fn {_id, name} -> "#{name}@example.com" == email end) do
      {id, _name} -> %{ok: true, user: %{id: id}}
      nil -> %{ok: false, error: "users_not_found"}
    end
  end

  defp reply("chat.getPermalink", %{"message_ts" => ts}),
    do: %{ok: true, permalink: "https://acme.slack.com/archives/C1/p#{ts}"}

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
