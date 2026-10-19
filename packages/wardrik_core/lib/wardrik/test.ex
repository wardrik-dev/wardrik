defmodule Wardrik.Test do
  @moduledoc """
  A suite run on core alone.

  `start/1` starts ExUnit once the runtime is ready, so a `test_helper.exs`
  reads:

      Wardrik.Test.start()

  `run/1` builds the run a turn runs under, and `call/4` runs one tool
  call through the same steps a turn runs it: what its tool declares, the
  hooks, the ledger, the credentials, the tool, and what its answer says of
  the run. A call that comes back waiting on a person is run on with
  `resume/2`, as a turn runs it once they approve. `check/3` stops at the
  hooks, and `context/2` hands a tool its arguments directly.

      run = Wardrik.Test.run(tools: [MyPack.Tools], hooks: hooks)
      call = Wardrik.Test.call(run, "search", %{"query" => "otp"})
      assert %Wardrik.Call{state: :done, result: {:ok, _found}} = call

  The runtime keeps everything in a `WardrikStore.Memory` store, unless the
  suite's configuration names another, and runs on a host offering the
  seams it names, each by its module and the fields of its struct:

      config :wardrik_core, Wardrik.Test,
        store: [adapter: WardrikStore.EKV, data_dir: "/tmp/my-suite"],
        host: [definitions: {MyApp.Specs, []}]

  `store/0` and `host/1` are the store and the host that runtime started on,
  for a test to hand what it calls. The host's `Wardrik.LLM.Client` is
  `llm/0`, which answers every agent's model calls from the script a test
  sets on it; see `Wardrik.Test.LLM`. It runs `Wardrik.Test.Runtime` beside
  `Wardrik.LLM.Runtime`, so an agent whose config is a `Wardrik.Test.Script`
  runs turns a test writes in place of a model's:

      config = Wardrik.Test.Script.new({Wardrik.Test.AgentRunners, :echo, [self(), "ok"]})
      {id, pid} = Wardrik.Test.Fleet.start_agent(config: config)

  The modules under this one stand in for parts of a run: `Wardrik.Test.Fleet`
  starts an agent under a key of each test's own, `Wardrik.Test.LLM`
  answers model calls from a script, `Wardrik.Test.Tools` has a gated
  tool, one that reads from outside, and a hook that decides calls by rules,
  and `WardrikStore.Test.Durable` checks a store adapter of your own.
  """

  alias Wardrik.Call
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run

  @doc """
  Starts ExUnit once the runtime is ready.

  Starts what `children:` names in order, `children/0` by default, waits
  for the fleet, then waits for every supervisor `wait:` names, as
  `DurableServer.Supervisor.wait_until_ready/2` does:

      Wardrik.Test.start(
        children: Wardrik.Test.children() ++ [{WardrikPolicy.Supervisor, store: Wardrik.Test.store()}],
        wait: [WardrikPolicy.Meter.supervisor()]
      )

  Once the suite is over, removes the store's `:data_dir` where it has one.

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
  The store, the holder of `llm/0`'s script, then core on `host/1`: the
  runtime a suite starts by default, before what runs on it.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children,
    do: [
      {WardrikStore, store()},
      {Wardrik.Test.LLM, name: llm().script},
      {Wardrik.Core, host: host()}
    ]

  @doc """
  The suite's `Wardrik.Test.LLM`, which `host/1` gives every agent, its
  holder the one `children/0` starts.
  """
  @spec llm() :: Wardrik.Test.LLM.t()
  def llm, do: %Wardrik.Test.LLM{script: Wardrik.Test.LLM}

  # The store's settings, as the suite's configuration names them.
  defp settings,
    do: Keyword.get(config(), :store, adapter: WardrikStore.Memory)

  defp config, do: Application.get_env(:wardrik_core, __MODULE__, [])

  @doc "The store the runtime started on, as the suite's configuration names it."
  @spec store() :: WardrikStore.t()
  def store, do: WardrikStore.new(settings())

  @doc """
  The host the runtime started on, with `store/0`, `llm/0`, `runtimes/0` and
  the seams the suite's configuration names, and those `opts` name over them.
  """
  @spec host(keyword()) :: Wardrik.Host.t()
  def host(opts \\ []) do
    seams =
      for {seam, {module, fields}} <- Keyword.get(config(), :host, []),
          do: {seam, struct!(module, fields)}

    Wardrik.Host.new(
      Keyword.merge([store: store(), llm: llm(), runtimes: runtimes()] ++ seams, opts)
    )
  end

  @doc "`Wardrik.LLM.Runtime` and `Wardrik.Test.Runtime`, which `host/1` runs."
  @spec runtimes() :: [Wardrik.Runtime.t()]
  def runtimes, do: [%Wardrik.LLM.Runtime{}, %Wardrik.Test.Runtime{}]

  @doc """
  The run a turn would run under, for an agent of this test's own.

  `tools:` names the tools, as `Wardrik.LLM.Config` takes them, or `config:`
  gives the whole config; `id:` names the agent, in place of one no other
  test uses; `llm:` is the model client its host has, `llm/0` unless given.
  The rest is what `Wardrik.Run.root/3` takes: the hooks, and the host,
  `host/1` unless given.
  """
  @spec run(keyword()) :: Run.t()
  def run(opts \\ []) do
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {config, opts} = Keyword.pop_lazy(opts, :config, fn -> Config.new(tools: tools) end)
    {id, opts} = Keyword.pop_lazy(opts, :id, &Wardrik.Test.Fleet.id/0)
    {llm, opts} = Keyword.pop_lazy(opts, :llm, &llm/0)
    Run.root(config, id, Keyword.put_new_lazy(opts, :host, fn -> host(llm: llm) end))
  end

  @doc """
  Runs one call to the tool `name` with `arguments`, under `run`, through
  the steps a turn runs it, and hands back the call as it came out: `:done`
  with its `:result`, or `:waiting` on a person. `id:` is the call's id, in
  place of one of its own.
  """
  @spec call(Run.t(), String.t(), map(), keyword()) :: Call.t()
  def call(%Run{} = run, name, arguments \\ %{}, opts \\ []) when is_binary(name),
    do: run |> proposed(name, arguments, opts) |> ToolRunner.execute(run)

  @doc """
  What the run's hooks say of one call to the tool `name` with `arguments`,
  with what its tool declares written on it first and nothing run: the call
  as `:allowed`, `:denied` or `:waiting`.
  """
  @spec check(Run.t(), String.t(), map()) :: Call.t()
  def check(%Run{} = run, name, arguments \\ %{}) when is_binary(name),
    do: run |> proposed(name, arguments, []) |> Wardrik.Call.Pipeline.decide()

  @doc """
  The context a tool is handed for one call under `run`, for a test that
  hands a tool its arguments directly.
  `credentials:` are what the runtime would have resolved for it, by name,
  `name:` the tool's name and `id:` the call's.
  """
  @spec context(Run.t(), keyword()) :: Wardrik.Tool.Context.t()
  def context(%Run{} = run, opts \\ []) do
    {credentials, opts} = Keyword.pop(opts, :credentials, %{})
    {name, opts} = Keyword.pop(opts, :name, "tool")
    Wardrik.Tool.Context.new(proposed(run, name, %{}, opts), credentials)
  end

  defp proposed(run, name, arguments, opts) do
    id = Keyword.get_lazy(opts, :id, fn -> "call_#{System.unique_integer([:positive])}" end)
    %Call{id: id, target: %Call.Tool{name: name, arguments: arguments}, run: run}
  end

  @doc """
  Runs on a call `call/4` handed back waiting, as a turn does once a person
  approves it: the hooks are not asked again, and the tool runs, or is
  handed the call again where it parked.
  """
  @spec resume(Run.t(), Call.t()) :: Call.t()
  def resume(%Run{} = run, %Call{state: :waiting} = call),
    do: call |> Call.approve() |> ToolRunner.execute(run)
end
