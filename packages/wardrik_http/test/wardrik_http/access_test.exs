defmodule WardrikHTTP.AccessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.Grant
  alias Wardrik.Store
  alias WardrikHTTP.Access
  alias WardrikHTTP.Access.Cache
  alias WardrikHTTP.Access.Leases

  @ns :access_test

  # A record written as a surface writes one, and its ref.
  defp record(value \\ :granted) do
    key = "record-#{System.unique_integer([:positive])}"
    {:ok, _vsn} = Store.put(@ns, key, value, if_vsn: nil)
    {@ns, key}
  end

  # A process that holds `ref`, tells the test what it receives, and runs
  # until it is ended. With `trap: true` it traps exits, as a connection
  # process does, and ends itself on a revocation only where `obey: true`.
  defp holder(ref, opts \\ []) do
    test = self()

    pid =
      spawn(fn ->
        if opts[:trap], do: Process.flag(:trap_exit, true)
        send(test, {:held, self(), Access.hold(ref)})
        listen(test, opts[:obey])
      end)

    assert_receive {:held, ^pid, :ok}
    Process.monitor(pid)
    pid
  end

  defp listen(test, obey) do
    receive do
      {:EXIT, _from, {:shutdown, :revoked}} = exit when obey ->
        send(test, {:got, self(), exit})

      message ->
        send(test, {:got, self(), message})
        listen(test, obey)
    end
  end

  # Makes what this node read of `ref` lapse, as a sweep's time passing does.
  defp lapse(ref) do
    [{^ref, value, _until}] = :ets.lookup(Cache, ref)
    true = :ets.insert(Cache, {ref, value, System.monotonic_time(:millisecond) - 1})
  end

  defp grace(ms) do
    previous = Application.get_env(:wardrik_http, Access, [])
    Application.put_env(:wardrik_http, Access, Keyword.put(previous, :grace, ms))
    on_exit(fn -> Application.put_env(:wardrik_http, Access, previous) end)
  end

  describe "authorize/3" do
    test "wants a grant that reaches the agent and allows the action" do
      {:ok, reader} = Grant.new("acme/", [:read])
      {:ok, decider} = Grant.new("acme/@ops/", [:decide])

      assert :ok = Access.authorize(reader, :read, "acme/@ops/deploy")
      assert {:error, :forbidden} = Access.authorize(reader, :decide, "acme/@ops/deploy")
      assert {:error, :not_found} = Access.authorize(reader, :read, "globex/deploy")

      assert :ok = Access.authorize([reader, decider], :decide, "acme/@ops/deploy")
      assert {:error, :forbidden} = Access.authorize([reader, decider], :decide, "acme/@jon/x")
      assert {:error, :not_found} = Access.authorize([], :read, "acme/@ops/deploy")
    end
  end

  test "fetch/2 reads a record through consensus, or says it is not there" do
    ref = record(:value)
    assert {:ok, :value} = Access.fetch(ref)
    assert {:ok, :value} = Access.fetch(ref, timeout: 1_000)
    assert {:error, :not_found} = Access.fetch({@ns, "absent"})
  end

  describe "get/1" do
    test "reads a record through consensus once, then answers what it read for a sweep" do
      {ns, key} = ref = record(:value)
      assert {:ok, :value} = Access.get(ref)

      # Gone from the store without a revocation: this node still answers
      # what it read, until the entry lapses.
      {_value, vsn} = Store.lookup(ns, key)
      :ok = Store.delete(ns, key, if_vsn: vsn)
      assert {:ok, :value} = Access.get(ref)

      lapse(ref)
      assert {:error, :not_found} = Access.get(ref)
    end

    test "answers a record this node has never held as not there" do
      assert {:error, :not_found} = Access.get({@ns, "never-written"})
    end

    test "refuses a revoked record at once, and nothing read before brings it back" do
      ref = record(:value)
      assert {:ok, :value} = Access.get(ref)

      :ok = Access.revoke(ref)
      assert {:error, :not_found} = Access.get(ref)

      # A read begun before the revocation, landing after it.
      :ok = Cache.put(ref, :value)
      assert :revoked = Cache.lookup(ref)
      assert {:error, :not_found} = Access.get(ref)
    end

    test "reads a record again once what it read has lapsed" do
      ref = record(:value)
      assert {:ok, :value} = Access.get(ref)

      lapse(ref)
      assert :miss = Cache.lookup(ref)
      assert {:ok, :value} = Access.get(ref)
      assert {:ok, :value} = Cache.lookup(ref)
    end
  end

  test "a purge drops what has lapsed, and keeps the rest" do
    lapsed = record()
    kept = record()
    {:ok, _value} = Access.get(lapsed)
    {:ok, _value} = Access.get(kept)
    lapse(lapsed)

    :ok = Cache.purge()

    assert :ets.lookup(Cache, lapsed) == []
    assert [{^kept, :granted, _until}] = :ets.lookup(Cache, kept)
  end

  describe "revoke/1" do
    test "ends a holder with {:shutdown, :revoked}, and deletes the record" do
      ref = record()
      pid = holder(ref)

      assert :ok = Access.revoke(ref)

      assert_receive {:DOWN, _monitor, :process, ^pid, {:shutdown, :revoked}}
      assert {:error, :not_found} = Access.fetch(ref)
      assert {:error, :not_found} = Access.revoke(ref)
    end

    test "tells a holder that traps exits, which ends itself" do
      ref = record()
      pid = holder(ref, trap: true, obey: true)

      :ok = Access.revoke(ref)

      assert_receive {:got, ^pid, {:EXIT, _from, {:shutdown, :revoked}}}
      assert_receive {:DOWN, _monitor, :process, ^pid, :normal}
    end

    test "kills a holder still alive after the grace" do
      grace(50)
      ref = record()
      pid = holder(ref, trap: true)

      log =
        capture_log(fn ->
          :ok = Access.revoke(ref)
          assert_receive {:got, ^pid, {:EXIT, _from, {:shutdown, :revoked}}}
          assert_receive {:DOWN, _monitor, :process, ^pid, :killed}, 1_000
        end)

      assert log =~ "held access_test/"
      assert log =~ "past its revocation, and was killed"
    end

    test "leaves a holder of another record be" do
      ref = record()
      other = holder(record())
      _pid = holder(ref)

      :ok = Access.revoke(ref)

      refute_receive {:DOWN, _monitor, :process, ^other, _reason}, 100
      assert Process.alive?(other)
    end
  end

  test "hold/1 holds nothing where the record is gone" do
    assert {:error, :not_found} = Access.hold({@ns, "absent"})
  end

  test "holding/2 lets go once its function returns, and the process is never ended for it" do
    grace(50)
    ref = record()
    test = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(test, {:ran, Access.holding(ref, fn -> :answered end)})
        listen(test, false)
      end)

    Process.monitor(pid)
    assert_receive {:ran, :answered}

    :ok = Access.revoke(ref)

    refute_receive {:got, ^pid, _message}, 200
    refute_received {:DOWN, _monitor, :process, ^pid, _reason}
    Process.exit(pid, :kill)
  end

  test "a sweep that fails ends every holder on the node" do
    pid = holder(record())
    test = self()

    # A ref the store refuses to read makes the sweep itself fail.
    bystander =
      spawn(fn ->
        Leases.hold({"not a namespace", "key"})
        send(test, :registered)
        receive do: (:never -> :ok)
      end)

    Process.monitor(bystander)
    assert_receive :registered

    log = capture_log(fn -> :ok = Leases.sweep() end)

    assert log =~ "A sweep of held records failed, so their holders are ended"
    assert_receive {:DOWN, _monitor, :process, ^pid, {:shutdown, :revoked}}
    assert_receive {:DOWN, _monitor, :process, ^bystander, {:shutdown, :revoked}}
  end

  test "a sweep ends the holders of a record deleted without a revocation reaching them" do
    {ns, key} = ref = record()
    pid = holder(ref)

    {_value, vsn} = Store.lookup(ns, key)
    :ok = Store.delete(ns, key, if_vsn: vsn)
    refute_receive {:DOWN, _monitor, :process, ^pid, _reason}, 50

    :ok = Leases.sweep()

    assert_receive {:DOWN, _monitor, :process, ^pid, {:shutdown, :revoked}}
  end
end
