defmodule Wardrik.Test do
  @moduledoc """
  A suite run on core alone.

  `start/1` starts ExUnit once the runtime is ready, so a `test_helper.exs`
  reads:

      Wardrik.Test.start()

  `scope/1` builds the scope a turn runs under, and `call/4` runs one tool
  call through the same steps a turn runs it: what its tool declares, the
  hooks, the ledger, the tool, and what its answer says of the run. A call
  that comes back waiting on a person is run on with `resume/2`, as a turn
  runs it once they approve.

      scope = Wardrik.Test.scope(tools: [MyPack.Tools], hooks: hooks)
      call = Wardrik.Test.call(scope, "search", %{"query" => "otp"})
      assert %Wardrik.Call{state: :done, result: {:ok, _found}} = call

  The runtime is the one `config :wardrik` names, so a suite that needs
  nothing kept sets `config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory`
  and nothing else.

  The modules under this one stand in for parts of a run: `Wardrik.Test.Fleet`
  starts an agent under a key of each test's own, `Wardrik.Test.LLMStub`
  answers turns with canned responses, `Wardrik.Test.Tools` has a gated
  tool, one that reads from outside, and a hook that decides calls by rules,
  and `Wardrik.Test.Durable` checks a store adapter of your own.
  """

  alias Wardrik.Call
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  @doc """
  Starts ExUnit once the runtime is ready.

  Waits for the fleet and the schedules, and for every supervisor `wait:`
  names, as `DurableServer.Supervisor.wait_until_ready/2` does. Loads the
  model catalog, which the application starts loading in the background,
  so the wait for it lands on no test. Copies what `Wardrik.Test.LLMStub`
  stubs where `llm_stub: true`. Once the suite is over, removes the store's
  `:data_dir` where it has one.

  Every other option goes to `ExUnit.start/1`, over `capture_log: true` and
  an `assert_receive_timeout` of a second: an `assert_receive` returns as
  soon as its message arrives, so a generous timeout costs a passing test
  nothing and keeps a suite running many cases at once from failing one
  whose message was merely late.
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    {wait, opts} = Keyword.pop(opts, :wait, [])
    {llm_stub, opts} = Keyword.pop(opts, :llm_stub, false)

    if llm_stub, do: Wardrik.Test.LLMStub.copy()
    _loaded = ReqLLM.model("test:model")
    Enum.each([Wardrik.Fleet, Wardrik.Schedule.supervisor() | wait], &ready!/1)
    ExUnit.after_suite(fn _results -> remove_store() end)
    ExUnit.start(Keyword.merge([capture_log: true, assert_receive_timeout: 1_000], opts))
  end

  defp ready!(name), do: :ok = DurableServer.Supervisor.wait_until_ready(name, timeout: 10_000)

  # A store kept on disk for this run alone goes with it. The fleet closes it
  # first, and the OS monitor closes its helper before the VM takes its ports.
  # A file written while the directory goes is left where it is.
  defp remove_store do
    case Wardrik.Store.config()[:data_dir] do
      nil ->
        :ok

      dir ->
        Supervisor.stop(Wardrik.Fleet.Supervisor)
        _ = File.rm_rf(dir)
        _ = Application.stop(:os_mon)
        :ok
    end
  end

  @doc """
  The scope a turn would run under, for a key of this test's own.

  `tools:` names the tools, as `Wardrik.LLM.Config` takes them, or `config:`
  gives the whole config; `key:` names the agent, in place of one no other
  test uses. The rest is what `Wardrik.Scope.root/3` takes: the hooks, the
  user and org, the credentials, the ledger and the dispatch.
  """
  @spec scope(keyword()) :: Scope.t()
  def scope(opts \\ []) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {config, opts} = Keyword.pop_lazy(opts, :config, fn -> Config.new(tools: tools) end)
    {key, opts} = Keyword.pop_lazy(opts, :key, &Wardrik.Test.Fleet.key/0)
    Scope.root(config, key, opts)
  end

  @doc """
  Runs one call to the tool `name` with `arguments`, under `scope`, through
  the steps a turn runs it, and hands back the call as it came out: `:done`
  with its `:result`, or `:waiting` on a person. `id:` is the call's id, in
  place of one of its own.
  """
  @spec call(Scope.t(), String.t(), map(), keyword()) :: Call.t()
  def call(%Scope{} = scope, name, arguments \\ %{}, opts \\ []) when is_binary(name),
    do: scope |> proposed(name, arguments, opts) |> ToolRunner.execute(scope)

  @doc """
  What the scope's hooks say of one call to the tool `name` with `arguments`,
  with what its tool declares written on it first and nothing run: the call
  as `:allowed`, `:denied` or `:waiting`.
  """
  @spec check(Scope.t(), String.t(), map()) :: Call.t()
  def check(%Scope{} = scope, name, arguments \\ %{}) when is_binary(name),
    do: scope |> proposed(name, arguments, []) |> Wardrik.Tool.declared() |> Wardrik.Hook.check()

  defp proposed(scope, name, arguments, opts) do
    id = Keyword.get_lazy(opts, :id, fn -> "call_#{System.unique_integer([:positive])}" end)
    %Call{id: id, target: %Call.Tool{name: name, arguments: arguments}, scope: scope}
  end

  @doc """
  Runs on a call `call/4` handed back waiting, as a turn does once a person
  approves it: the hooks are not asked again, and the tool runs, or is
  handed the call again where it parked.
  """
  @spec resume(Scope.t(), Call.t()) :: Call.t()
  def resume(%Scope{} = scope, %Call{state: :waiting} = call),
    do: call |> Call.approve() |> ToolRunner.execute(scope)
end
