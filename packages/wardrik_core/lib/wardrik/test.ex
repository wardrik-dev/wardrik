defmodule Wardrik.Test do
  @moduledoc """
  A suite run on core alone.

  `start/1` starts ExUnit once the runtime is ready, so a `test_helper.exs`
  reads:

      Wardrik.Test.start()

  `scope/1` builds the scope a turn runs under, and `call/4` runs one tool
  call through the same steps a turn runs it: what its tool declares, the
  hooks, the ledger, the credentials, the tool, and what its answer says of
  the run. A call that comes back waiting on a person is run on with
  `resume/2`, as a turn runs it once they approve. `check/3` stops at the
  hooks, and `context/2` hands a tool its arguments directly.

      scope = Wardrik.Test.scope(tools: [MyPack.Tools], hooks: hooks)
      call = Wardrik.Test.call(scope, "search", %{"query" => "otp"})
      assert %Wardrik.Call{state: :done, result: {:ok, _found}} = call

  The runtime keeps everything in a `WardrikStore.Memory` store, unless the
  suite's configuration names another, and runs on a host offering the
  seams it names, each by its module and the fields of its struct:

      config :wardrik_core, Wardrik.Test,
        store: [adapter: WardrikStore.EKV, data_dir: "/tmp/my-suite"],
        host: [definitions: {MyApp.Definitions, []}]

  `store/0` and `host/1` are the store and the host that runtime started on,
  for a test to hand what it calls.

  The modules under this one stand in for parts of a run: `Wardrik.Test.Fleet`
  starts an agent under a key of each test's own, `Wardrik.Test.LLMStub`
  answers turns with canned responses, `Wardrik.Test.Tools` has a gated
  tool, one that reads from outside, and a hook that decides calls by rules,
  and `WardrikStore.Test.Durable` checks a store adapter of your own.
  """

  alias Wardrik.Call
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  @doc """
  Starts ExUnit once the runtime is ready.

  Starts what `children:` names in order, `children/0` by default, waits
  for the fleet, then waits for every supervisor `wait:` names, as
  `DurableServer.Supervisor.wait_until_ready/2` does:

      Wardrik.Test.start(
        children: Wardrik.Test.children() ++ [{WardrikPolicy.Supervisor, store: Wardrik.Test.store()}],
        wait: [WardrikPolicy.Meter.supervisor()]
      )

  Loads the
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
    {children, opts} = Keyword.pop_lazy(opts, :children, &children/0)
    {wait, opts} = Keyword.pop(opts, :wait, [])
    {llm_stub, opts} = Keyword.pop(opts, :llm_stub, false)

    if llm_stub, do: Wardrik.Test.LLMStub.copy()
    _loaded = ReqLLM.model("test:model")

    {:ok, _pid} =
      Supervisor.start_link(children, strategy: :rest_for_one, name: Wardrik.Test.Supervisor)

    Enum.each([Wardrik.Fleet | wait], &ready!/1)
    ExUnit.after_suite(fn _results -> remove_store(settings()[:data_dir]) end)
    ExUnit.start(Keyword.merge([capture_log: true, assert_receive_timeout: 1_000], opts))
  end

  defp ready!(name), do: :ok = DurableServer.Supervisor.wait_until_ready(name, timeout: 10_000)

  # A store kept on disk for this run alone goes with it. What runs on the
  # fleet stops first, then the fleet closes the store, and the OS monitor
  # closes its helper before the VM takes its ports. A file written while the
  # directory goes is left where it is.
  defp remove_store(nil), do: Supervisor.stop(Wardrik.Test.Supervisor)

  defp remove_store(dir) do
    Supervisor.stop(Wardrik.Test.Supervisor)
    _ = File.rm_rf(dir)
    _ = Application.stop(:os_mon)
    :ok
  end

  @doc """
  The store, then core on `host/1`: the runtime a suite starts by default,
  before what runs on it.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children, do: [{WardrikStore, store()}, {Wardrik.Core, host: host()}]

  # The store's settings, as the suite's configuration names them.
  defp settings,
    do: Keyword.get(config(), :store, adapter: WardrikStore.Memory)

  defp config, do: Application.get_env(:wardrik_core, __MODULE__, [])

  @doc "The store the runtime started on, as the suite's configuration names it."
  @spec store() :: WardrikStore.t()
  def store, do: WardrikStore.new(settings())

  @doc """
  The host the runtime started on, with `store/0` and the seams the suite's
  configuration names, and those `opts` name over them.
  """
  @spec host(keyword()) :: Wardrik.Host.t()
  def host(opts \\ []) do
    seams =
      for {seam, {module, fields}} <- Keyword.get(config(), :host, []),
          do: {seam, struct!(module, fields)}

    Wardrik.Host.new(Keyword.merge([store: store()] ++ seams, opts))
  end

  @doc """
  The scope a turn would run under, for an agent of this test's own.

  `tools:` names the tools, as `Wardrik.LLM.Config` takes them, or `config:`
  gives the whole config; `id:` names the agent, in place of one no other
  test uses. The rest is what `Wardrik.Scope.root/3` takes: the hooks, the
  ledger, and the host, `host/1` unless given.
  """
  @spec scope(keyword()) :: Scope.t()
  def scope(opts \\ []) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {config, opts} = Keyword.pop_lazy(opts, :config, fn -> Config.new(tools: tools) end)
    {id, opts} = Keyword.pop_lazy(opts, :id, &Wardrik.Test.Fleet.id/0)
    Scope.root(config, id, Keyword.put_new_lazy(opts, :host, &host/0))
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
    do: scope |> proposed(name, arguments, []) |> Wardrik.Call.Pipeline.decide()

  @doc """
  The context a tool built with `Wardrik.Tool.new!/1` is handed for one call
  under `scope`, for a test that hands a tool its arguments directly.
  `credentials:` are what the runtime would have resolved for it, by name,
  `name:` the tool's name and `id:` the call's.
  """
  @spec context(Scope.t(), keyword()) :: Wardrik.Tool.Context.t()
  def context(%Scope{} = scope, opts \\ []) do
    {credentials, opts} = Keyword.pop(opts, :credentials, %{})
    {name, opts} = Keyword.pop(opts, :name, "tool")
    Wardrik.Tool.Context.new(proposed(scope, name, %{}, opts), credentials)
  end

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
