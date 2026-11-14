defmodule WardrikDaemon.RestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config

  @document %{
    "kind" => "discovery#restDescription",
    "name" => "notes",
    "auth" => %{"oauth2" => %{}},
    "resources" => %{
      "notes" => %{
        "methods" => %{
          "list" => %{
            "id" => "notes.notes.list",
            "httpMethod" => "GET",
            "path" => "v1/notes",
            "scopes" => ["notes"]
          }
        }
      }
    }
  }

  setup context do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    start_supervised!({Wardrik.Store, store})
    store = Wardrik.Store.scope(store, "wardrik_daemon")
    wardrik = Module.concat(__MODULE__, "W#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "rest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    notes = Path.join(dir, "notes.json")
    File.write!(notes, JSON.encode!(@document))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store, wardrik: wardrik, dir: dir}
  end

  defp entry(discovery) do
    %Config.Rest{
      reader: :discovery,
      location: discovery,
      options: [base_url: "https://notes.test/", auth: %{"oauth2" => {:credential, "notes"}}]
    }
  end

  defp started(context, apis, opts \\ []) do
    config = %Config{
      org: "platform",
      orgs: %{
        "growth" => %{
          mcp: [],
          harnesses: [],
          rest: ["notes"],
          channels: [],
          notify: [],
          policy: nil
        }
      },
      rest: apis
    }

    start_supervised!(
      {WardrikDaemon.Rest,
       [
         name: WardrikDaemon.Rest.name(context.wardrik),
         apis: apis,
         dir: context.dir,
         egress: &WardrikRest.API.https/1
       ] ++ opts}
    )

    WardrikDaemon.Rest.capabilities(context.wardrik, context.store, config)
  end

  defp offered(context, capabilities, owner) do
    {:ok, record} =
      AgentRecords.create(context.store,
        owner: owner,
        name: "analyst#{System.unique_integer([:positive])}",
        source: :api
      )

    agent = Wardrik.Context.new(agent_id: record.id)
    for {_name, {module, opts}} <- capabilities, tool <- module.tools(agent, opts), do: tool.name
  end

  test "names a tool group after each API, for the orgs that use it", context do
    capabilities = started(context, [{"notes", entry("notes.json")}])

    assert [{"notes", _capability}] = capabilities
    assert offered(context, capabilities, "growth") == ["notes__notes_list"]
    assert offered(context, capabilities, "platform") == []
  end

  test "reads an OpenAPI document in YAML, with a scheme it doesn't name", context do
    notes = Path.join(context.dir, "notes.yaml")

    File.write!(notes, """
    openapi: 3.1.0
    info: {title: Notes}
    paths:
      /notes:
        get: {operationId: notes.list}
    """)

    entry = %Config.Rest{
      reader: :openapi,
      location: "notes.yaml",
      options: [
        base_url: "https://notes.test/v1",
        schemes: %{"token" => :bearer},
        auth: %{"token" => {:credential, "notes"}}
      ]
    }

    capabilities = started(context, [{"notes", entry}])
    assert offered(context, capabilities, "growth") == ["notes__notes_list"]
  end

  test "fetches a description from its URL", context do
    Req.Test.stub(context.test, &Req.Test.json(&1, @document))

    capabilities =
      started(context, [{"notes", entry("https://notes.test/$discovery/rest")}],
        req_options: [plug: {Req.Test, context.test}]
      )

    assert offered(context, capabilities, "growth") == ["notes__notes_list"]
  end

  test "offers no tools while a description doesn't read, and says why", context do
    log =
      capture_log(fn ->
        capabilities =
          started(context, [
            {"notes", entry("missing.json")},
            {"plain", entry("http://notes.test/rest")}
          ])

        assert offered(context, capabilities, "growth") == []
      end)

    assert log =~ "rest.notes isn't read: #{context.dir}/missing.json doesn't read: :enoent."
    assert log =~ "rest.plain isn't read: http://notes.test/rest isn't an https URL."
  end

  test "reads a description again until it does", context do
    {capabilities, _log} = with_log(fn -> started(context, [{"notes", entry("later.json")}]) end)

    assert offered(context, capabilities, "growth") == []

    later = Path.join(context.dir, "later.json")
    File.write!(later, JSON.encode!(@document))
    send(WardrikDaemon.Rest.name(context.wardrik), :read)

    assert offered(context, capabilities, "growth") == ["notes__notes_list"]
  end
end
