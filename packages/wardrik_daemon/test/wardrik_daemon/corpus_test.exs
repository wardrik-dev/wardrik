defmodule WardrikDaemon.CorpusTest do
  use ExUnit.Case, async: true

  # What each release of the daemon stores, kept as the store wrote it in
  # test/corpus/<version>.json. Every later release must read all of it. A release writes its own
  # with:
  #
  #     mix test test/wardrik_daemon/corpus_test.exs --only corpus

  alias Wardrik.Store.Format
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Tokens

  @corpus Path.expand("../corpus", __DIR__)

  @formats %{
    "wardrik_daemon" => Format.JSON,
    "wardrik_daemon/tokens" => Tokens,
    "wardrik_daemon/agent_records" => AgentRecords
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
    File.mkdir_p!(@corpus)
    rows = JSON.encode!(kept())
    path = Path.join(@corpus, version <> ".json")
    File.write!(path, rows)
  end

  defp rows(file) do
    file
    |> File.read!()
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
    [scope, _key] = String.split(path, ":", parts: 2)

    format =
      Map.get(@formats, scope) || flunk("#{release} keeps #{scope}, which nothing here reads")

    assert {:ok, _value} = Format.decode(format, text), "#{release}: #{path}"
  end

  # One of each kind of value the daemon keeps, written through the store as it writes them.
  defp kept do
    store = Wardrik.Store.ETS.new(name: :"daemon corpus #{System.unique_integer([:positive])}")
    start_supervised!({Wardrik.Store, store})
    daemon = Wardrik.Store.scope(store, "wardrik_daemon")

    {:ok, _created} =
      Tokens.create(daemon,
        name: "laptop",
        subject: "user:acme/@ana",
        groups: ["eng"],
        expires: ~U[2027-01-01 00:00:00Z]
      )

    {:ok, record} = AgentRecords.create(daemon, owner: "acme", name: "triage", source: :file)
    {:ok, _vsn} = Wardrik.Store.put(daemon, "agent files", %{"triage.md" => record.id})

    ceiling = %{
      "period" => "month/2026-11-01",
      "usd" => 12.5,
      "tokens" => 4000,
      "granted" => %{"usd" => 10},
      "unpriced" => false
    }

    {:ok, _vsn} = Wardrik.Store.put(daemon, "ceilings/acme/monthly", ceiling)

    raw(store)
  end
end
