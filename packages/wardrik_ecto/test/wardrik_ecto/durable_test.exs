defmodule WardrikEcto.DurableTest do
  use ExUnit.Case, async: false

  alias DurableServer.Meta
  alias DurableServer.StoredState
  alias Ecto.Adapters.SQL
  alias WardrikStore.Durable

  @moduletag :postgres

  setup do
    store = WardrikStore.new(adapter: WardrikEcto.Store, repo: WardrikEcto.Test.Repo)
    start_supervised!({WardrikStore, store})
    {:ok, %{state: state}} = Durable.init_backend(store: store)
    %{store: store, state: state}
  end

  test "holds a DurableServer in Postgres through a restart", %{store: store} do
    WardrikStore.Test.Durable.survives_a_restart(store, :durable_over_postgres)
  end

  # A deploy replaces a node with one under a new name, which has never seen
  # the name of the node that last held a server.
  test "reads a server last held on a node this one never saw", %{state: state} do
    key = unique()
    gone = "gone#{System.unique_integer([:positive])}@nohost"
    meta = stored().meta |> Meta.encode_to_binary() |> Base.decode64!() |> elsewhere(gone)
    body = %{"vsn" => 1, "state" => %{}, "meta" => Base.encode64(meta)}

    {:ok, _object} = Durable.put_object(state, key, body, [])

    assert {:ok, %{body: %StoredState{meta: %Meta{pid: pid}}}} =
             Durable.get_object(state, key, [])

    assert Atom.to_string(node(pid)) == gone
  end

  test "a server an earlier version kept with a node this one never saw is left out, not raised",
       %{store: store, state: state} do
    prefix = unique() <> "/"
    key = prefix <> "old"
    {:ok, _object} = Durable.put_object(state, prefix <> "new", stored(), [])
    {:ok, _vsn} = WardrikStore.put(store, :durable, key, :placeholder)

    old =
      stored()
      |> StoredState.to_storage_term()
      |> :erlang.term_to_binary()
      |> elsewhere("gone#{System.unique_integer([:positive])}@nohost")

    SQL.query!(
      WardrikEcto.Test.Repo,
      "UPDATE wardrik_records SET value = $1 WHERE ns = 'durable' AND key = $2",
      [old, key]
    )

    test = self()

    assert [%{key: new}] =
             state
             |> Durable.list_all_objects_stream(prefix,
               include_objects: true,
               error_handler: &send(test, &1)
             )
             |> Enum.to_list()

    assert new == prefix <> "new"
    assert_received {:decode_failed, ^key, %ArgumentError{}}
    assert {:error, %ArgumentError{}} = Durable.get_object(state, key, [])
  end

  defp stored,
    do: %StoredState{
      vsn: 1,
      state: %{},
      meta: %Meta{module: __MODULE__, pid: self(), status: :running}
    }

  # `binary`, an encoded term, with its pids on node `name` instead, without
  # making `name` an atom here.
  defp elsewhere(binary, name) do
    here = Atom.to_string(node())

    :binary.replace(
      binary,
      <<119, byte_size(here), here::binary>>,
      <<119, byte_size(name), name::binary>>,
      [:global]
    )
  end

  defp unique, do: "durable-ecto-test/#{System.unique_integer([:positive])}"
end
