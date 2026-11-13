defmodule WardrikDaemon.OperatorToolsTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikDaemon.HelpTools

  setup :set_mimic_global

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    allow_private_urls: true
    roles:
      workers:
        rules:
          - {verbs: [read, events], kinds: [agent]}
          - {verbs: [read, add], kinds: [mcp_server, notify_target, provider]}
          - {verbs: [read], kinds: [secret]}
      observer:
        rules:
          - {verbs: [nodes, runtime, audit], kinds: [deployment]}
          - {verbs: [read], kinds: [secret]}
    bindings:
      - {org: acme, role: workers, subjects: [agent:assistant]}
      - {org: deployment, role: observer, subjects: [agent:assistant]}
    """)

    write(context, "policies/sets.yaml", "allow: [notify_target_add]\n")

    write(context, "agents/assistant.md", """
    ---
    description: The assistant.
    tools: [settings, help, ops/read]
    policy: sets
    ---
    You run the deployment.
    """)

    start_daemon(context)
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    test = self()
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      send(test, {:sent, Enum.map_join(messages, "\n", &text/1)})
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp text(%{content: content}) when is_list(content),
    do: Enum.map_join(content, &to_string(Map.get(&1, :text, "")))

  defp text(_message), do: ""

  defp calling(calls) do
    tool_calls =
      for {id, name, args} <- calls, do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

    message = ReqLLM.Context.assistant("", tool_calls: tool_calls)
    %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
  end

  defp answer(text),
    do: %ReqLLM.Response{
      id: "resp",
      model: "test",
      context: nil,
      message: ReqLLM.Context.assistant(text)
    }

  # What the tools answered, as the model was sent it after the calls.
  defp results do
    assert_received {:sent, _first}
    assert_received {:sent, after_calls}
    after_calls
  end

  test "lists and adds settings, and hands a person the place to seal a secret", context do
    aide = id(context, "acme", "assistant")

    answers([
      calling([
        {"c1", "settings_list", %{"kind" => "notify_targets"}},
        {"c2", "notify_target_add", %{"name" => "ops", "url" => "http://127.0.0.1:9/ops"}},
        {"c3", "secret_request", %{"name" => "GITHUB_TOKEN", "purpose" => "api_key"}},
        {"c4", "agent_runs", %{"agent" => aide}},
        {"c5", "deployment_nodes", %{}}
      ]),
      answer("Done.")
    ])

    {:ok, _reply} = Wardrik.Agent.reply(context.admin, aide, "Set up notices.")

    assert {:ok, %{"targets" => [%{"name" => "ops", "url" => "http://127.0.0.1:9/ops"}]}} =
             Wardrik.run(context.admin, "notify_targets.list", %{"owner" => "acme"})

    sent = results()
    assert sent =~ "notify_targets"
    assert sent =~ "/web/secrets?owner=acme"
    assert sent =~ "wardrik vault put GITHUB_TOKEN --for api_key --org acme"
    assert sent =~ "runs"
    assert sent =~ ~s("asleep")
  end

  test "can't add what its role doesn't reach, or see a secret's value", context do
    aide = id(context, "acme", "assistant")

    answers([
      calling([
        {"c1", "notify_target_add",
         %{"owner" => "deployment", "name" => "ops", "url" => "http://127.0.0.1:9/ops"}},
        {"c2", "settings_list", %{"kind" => "secrets"}}
      ]),
      answer("Done.")
    ])

    {:ok, _reply} = Wardrik.Agent.reply(context.admin, aide, "Set up notices.")

    assert {:ok, %{"targets" => []}} =
             Wardrik.run(context.admin, "notify_targets.list", %{"owner" => "deployment"})

    sent = results()
    assert sent =~ "You may not do this to the notify targets of deployment."
    assert sent =~ "secrets"
  end

  test "lists the deployment's secrets by name, never by value", context do
    aide = id(context, "acme", "assistant")

    {:ok, nil} =
      Wardrik.run(context.admin, "secrets.put", %{
        "owner" => "deployment",
        "name" => "BRAVE_API_KEY",
        "value" => "bsk",
        "purpose" => "api_key"
      })

    answers([
      calling([{"c1", "settings_list", %{"kind" => "secrets", "owner" => "deployment"}}]),
      answer("Done.")
    ])

    {:ok, _reply} = Wardrik.Agent.reply(context.admin, aide, "Is there a Brave key?")

    sent = results()
    assert sent =~ "BRAVE_API_KEY"
    assert sent =~ "api_key"
    refute sent =~ "bsk"
  end

  describe "help" do
    setup do
      pages = [
        %{
          "title" => "Triggers",
          "description" => "Start an agent on a clock, a feed or a webhook.",
          "url" => "https://docs.wardrik.dev/build/triggers/",
          "markdown" => "A trigger starts a run. Use `every` for a clock."
        },
        %{
          "title" => "Agent files",
          "description" => "Define agents in Markdown files.",
          "url" => "https://docs.wardrik.dev/reference/agent-files/",
          "markdown" => "Edit an agent file in the agents directory, then wardrik reload."
        }
      ]

      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"pages" => pages}))
      :ok
    end

    defp tools(docs) do
      context = %WardrikCore.Context{agent_id: "x", principal: nil}

      for tool <-
            HelpTools.tools(context,
              daemon: daemon(),
              docs: docs,
              req_options: [plug: {Req.Test, __MODULE__}]
            ),
          into: %{},
          do: {tool.name, tool}
    end

    defp call(tool, args), do: tool.run.(args, nil)

    test "says where this deployment keeps things", context do
      assert {:ok, about} = call(tools("http://docs.test/a.json")["wardrik_about"], %{})
      assert about["config_file"] == Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
      assert about["agent_files"] == Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents")
      assert about["org"] == "acme"
      assert about["dashboard"] =~ "/web"
    end

    test "finds and reads the documentation, and keeps using it when it stops loading" do
      tools = tools("http://docs.test/b.json")

      assert {:ok, %{"pages" => [%{"title" => "Triggers", "url" => url} | _rest]}} =
               call(tools["docs_search"], %{"query" => "What are triggers?"})

      assert {:ok, %{"markdown" => "A trigger starts a run." <> _rest}} =
               call(tools["docs_read"], %{"url" => url})

      assert {:error, _missing} = call(tools["docs_read"], %{"url" => "https://nowhere/"})

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))

      :persistent_term.put(
        {HelpTools, "http://docs.test/b.json"},
        {0, elem(:persistent_term.get({HelpTools, "http://docs.test/b.json"}), 1)}
      )

      assert {:ok, %{"pages" => [%{"title" => "Agent files"} | _rest]}} =
               call(tools["docs_search"], %{"query" => "edit an agent file"})
    end

    test "says where else to look when the documentation never loaded" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))

      assert {:error, message} =
               call(tools("http://docs.test/c.json")["docs_search"], %{"query" => "triggers"})

      assert message =~ "https://docs.wardrik.dev"
    end

    test "web_search says how to give it a key while it has none" do
      brave = WardrikDaemon.Capabilities.brave(daemon().wardrik)
      [tool] = WardrikBrave.tools(nil, brave: brave)
      assert tool.description =~ "wardrik vault put BRAVE_API_KEY --for api_key"
    end

    test "runs the doctor's checks" do
      assert {:ok, %{"checks" => checks}} =
               call(tools("http://docs.test/d.json")["wardrik_doctor"], %{})

      assert %{"status" => "ok", "check" => "config"} =
               Enum.find(checks, &(&1["check"] == "config"))
    end
  end

  defp daemon, do: WardrikDaemon.Web.Endpoint.config(:daemon)
end
