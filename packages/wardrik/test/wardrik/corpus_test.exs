defmodule Wardrik.CorpusTest do
  use ExUnit.Case, async: true

  # What each release stores, kept as the store wrote it in test/corpus/<version>.json. Every
  # later release must read all of it. A release writes its own with:
  #
  #     mix test test/wardrik/corpus_test.exs --only corpus

  alias DurableServer.Meta
  alias DurableServer.StoredState
  alias ReqLLM.Message.ContentPart
  alias Wardrik.Chat.Replies
  alias Wardrik.Credentials.Authorization
  alias Wardrik.MCP.Server
  alias Wardrik.OAuth.Apps
  alias Wardrik.Operations.NotifyTargets
  alias Wardrik.Operations.Servers
  alias Wardrik.Policy.Ask
  alias Wardrik.Policy.Spending
  alias Wardrik.Principal
  alias Wardrik.Store.Durable
  alias Wardrik.Store.Format
  alias Wardrik.ToolCall
  alias Wardrik.Vault.Sealed
  alias Wardrik.Workspace.File
  alias WardrikCore.Agent.State
  alias WardrikCore.Span

  @corpus Path.expand("../corpus", __DIR__)
  @middleware [{Wardrik.Policy.Middleware, []}]

  @formats %{
    "wardrik_vault" => Sealed,
    "wardrik_workspace" => File,
    "wardrik_owned/providers" => Apps,
    "wardrik_owned/servers" => Servers,
    "wardrik_owned/notify_targets" => NotifyTargets,
    "wardrik_mcp/servers" => Server,
    "wardrik_mcp/tools" => Format.JSON,
    "durable" => Format.JSON,
    "durable/unreadable" => Format.JSON
  }

  test "reads what every release kept" do
    files = Path.join(@corpus, "*.json")

    for file <- Path.wildcard(files),
        row <- rows(file),
        do: read!(row, Path.basename(file))
  end

  test "reads what this release keeps" do
    for row <- kept(), do: read!(row, "this release")
  end

  @tag :corpus
  test "writes this release's corpus" do
    version = Mix.Project.config()[:version]
    Elixir.File.mkdir_p!(@corpus)
    rows = JSON.encode!(kept())
    path = Path.join(@corpus, version <> ".json")
    Elixir.File.write!(path, rows)
  end

  defp rows(file) do
    file
    |> Elixir.File.read!()
    |> JSON.decode!()
  end

  defp raw(store) do
    paths = store.adapter.keys(store.config, "")

    for path <- Enum.sort(paths) do
      {text, _vsn} = store.adapter.lookup(store.config, path)
      %{"path" => path, "text" => text}
    end
  end

  defp read!(%{"path" => path, "text" => text}, release) do
    [scope, key] = String.split(path, ":", parts: 2)

    format =
      Map.get(@formats, scope) || flunk("#{release} keeps #{scope}, which nothing here reads")

    assert {:ok, value} = Format.decode(format, text), "#{release}: #{path}"
    agent!(scope, key, value, release)
  end

  defp agent!("durable", "wardrik/agents/" <> _key = key, value, release) do
    state =
      value["state"]
      |> State.load()
      |> State.configure(middleware: @middleware)

    assert State.ready?(state), "#{release}: #{key}: #{State.unreadable(state)}"
  end

  defp agent!(_scope, _key, _value, _release), do: :ok

  # One of each kind of value Wardrik keeps, written through the store as it writes them.
  defp kept do
    store = Wardrik.Store.ETS.new(name: :"corpus #{System.unique_integer([:positive])}")
    start_supervised!({Wardrik.Store, store})
    maria = %Principal{id: "acme/@maria", attributes: %{"name" => "Maria"}}

    vault = Wardrik.Store.scope(store, "wardrik_vault", format: Sealed)
    key = :crypto.strong_rand_bytes(32)

    for {path, kind} <- [{"acme/GITHUB", :secret}, {"acme%2F%40maria/github", :grant}] do
      sealed = Sealed.seal("value", key: key, path: path, kind: kind)
      {:ok, _vsn} = Wardrik.Store.put(vault, path, sealed)
    end

    file = %File{
      content: "Notes.",
      by: "agt_1",
      at: ~U[2026-11-13 12:00:00Z],
      labels: ["outside"]
    }

    {:ok, _version} =
      Wardrik.Workspace.Files.write(store,
        tree: "agents/agt_1",
        path: "notes.md",
        file: file,
        version: nil
      )

    owned(%{store: store})
    mcp(store)
    agents(store, maria)

    raw(store)
  end

  defp owned(wardrik) do
    app = %{
      owner: "acme",
      name: "linear",
      id: "abc",
      secret: "LINEAR_SECRET",
      opts: [
        issuer: "https://linear.app",
        client_id: "client",
        scopes: ["read"],
        client_auth: :basic,
        flow: :device,
        authorization_params: %{"prompt" => "consent"}
      ]
    }

    server = %{
      owner: "acme",
      name: "crm",
      url: "https://crm.test/mcp",
      auth: "oauth",
      provider: nil,
      credential: "acme:server:crm"
    }

    target = %{owner: "acme", name: "ops", url: "https://hooks.test/ops", secret: "SIGNING"}

    :ok = Wardrik.Owned.put(wardrik, Apps, app)
    :ok = Wardrik.Owned.put(wardrik, Servers, server)
    :ok = Wardrik.Owned.put(wardrik, NotifyTargets, target)
  end

  defp mcp(store) do
    mcp = Wardrik.Store.scope(store, "wardrik_mcp")

    opts = [
      transport:
        {:streamable_http,
         url: "https://crm.test/mcp",
         headers: %{"authorization" => ["Bearer ", {:secret, "CRM_KEY"}]}},
      prefix: "crm",
      owner: "acme",
      only: ["search"],
      gated: ["create_*"],
      cost: [usd: 0.001]
    ]

    servers = Wardrik.Store.scope(mcp, "servers", format: Server)
    {:ok, _vsn} = Wardrik.Store.put(servers, "acme:crm", opts)

    tools = [
      %{"name" => "search", "description" => "Search.", "inputSchema" => %{"type" => "object"}}
    ]

    listed = Wardrik.Store.scope(mcp, "tools")
    {:ok, _vsn} = Wardrik.Store.put(listed, "acme:crm", tools)
  end

  defp agents(store, maria) do
    {:ok, %{state: backend}} = Durable.init_backend(store: store)
    context = Wardrik.Context.new(agent_id: "acme/triage", middleware: @middleware)
    span = Span.root()

    messages = [
      ReqLLM.Context.user("Pay the bill.", %{
        id: "msg_1",
        sent_at: ~U[2026-11-13 12:00:00Z],
        principal: maria,
        labels: ["outside"]
      }),
      %ReqLLM.Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "Check first.", metadata: %{signature: "sig=="}},
          %ContentPart{type: :text, text: "Paying."},
          %ContentPart{type: :image, data: <<137, 80, 78, 71>>, media_type: "image/png"}
        ],
        tool_calls: [ReqLLM.ToolCall.new("c1", "books__pay", ~s({"amount":1200}))],
        reasoning_details: [
          %ReqLLM.Message.ReasoningDetails{
            text: "Check first.",
            signature: "s",
            provider: :anthropic
          }
        ]
      }
    ]

    parked = %{
      reason:
        {:tool_calls,
         [
           {%ToolCall{id: "c1", name: "books__pay", arguments: %{"amount" => 1200}},
            {:park, %Ask{interrupt: "tool_approval", message: "Pay $1,200?", labels: ["outside"]}}},
           {%ToolCall{id: "c2", name: "github__list"},
            {:park,
             %Authorization{url: "https://x.test/1", credential: "github", principal: maria}}},
           {%ToolCall{id: "c3", name: "mail__send"}, {:park, :in_doubt}},
           {%ToolCall{id: "c4", name: "echo"}, {:ok, %{"said" => "done"}}},
           {%ToolCall{id: "c5", name: "fail"}, {:error, "It failed."}}
         ]},
      messages: messages,
      metadata: %{},
      span: span,
      measurements: %{usd: 0.01, input_tokens: 120}
    }

    spent = %{
      0 => %{
        period: {:day, ~D[2026-11-13]},
        usd: 1.5,
        tokens: 300,
        granted: %{usd: 5},
        unpriced: false
      }
    }

    waiting = %{
      State.new(agent_id: "acme/triage", model: "anthropic:claude-haiku-4-5", context: context)
      | state: :waiting,
        parked: parked,
        messages: messages
    }

    waiting =
      put_in(waiting, [Access.key(:context), Access.key(:private)], %{
        Spending.Spent => spent,
        Spending.Counted => %{trace: span.trace, counted: %{usd: 0.01}}
      })

    due = %{
      waiting
      | agent_id: "acme/drafts",
        state: :running,
        parked: nil,
        checkpoint: %{
          messages: messages,
          calls: [%ToolCall{id: "c1", name: "books__pay", arguments: %{}}],
          rounds: 24,
          metadata: %{},
          private: %{},
          span: span,
          measurements: %{}
        }
    }

    asked = %{
      waiting
      | agent_id: "acme/budget",
        parked: %{parked | reason: %Ask{interrupt: "model_approval", message: "Over budget."}}
    }

    for state <- [waiting, due, asked] do
      stored = %StoredState{vsn: 1, state: State.dump(state), meta: %Meta{}}
      key = "wardrik/agents/" <> URI.encode_www_form(state.agent_id)
      {:ok, _put} = Durable.put_object(backend, key, stored, [])
    end

    room = %{
      Replies.State.new("T1", "C1")
      | cursor: "c-1",
        conversations: [{"acme/triage", "C1"}],
        senders: %{"msg_1" => "U1"},
        runs: %{{"acme/triage", "C1"} => %{id: "run_1", answering: ["msg_1"], asked_by: "U1"}}
    }

    stored = %StoredState{vsn: 2, state: Replies.State.dump(room), meta: %Meta{}}
    {:ok, _put} = Durable.put_object(backend, "wardrik/replies/T1/C1", stored, [])
  end
end
