defmodule WardrikNotify.Listener do
  @moduledoc """
  The `Wardrik.Listener` `WardrikNotify.Keeper` runs: for each turn an
  agent parked, failed or finished, it reads where the agent's notices go
  from its definition, `WardrikDefinition.Route`, as the event comes, and
  hands the `WardrikNotify.Notice` the route asks for to each target in
  turn. Then it hands the keeper the cursor past the event.

  An agent's route is read from the definition kept for it, by its ID, so
  a `Wardrik.Thread` of it, as `acme/books/1696.1234`, which has no
  definition of its own, is routed nowhere.

  Each delivery runs in a task of its own under `:tasks`, so a target that
  crashes is taken as one that failed: it is tried again after `:backoff`,
  then after twice that, and given up with a warning after the third
  attempt. A target `config.yaml` does not configure, or that does not tell
  the agent's org, is not tried again. The next event waits for the
  targets of the one before.

  Besides `Wardrik.Listener`'s, it takes `:keeper`, `:tasks`, `:targets`,
  `:req_options` and `:backoff`, as the keeper starts it.
  """

  use Wardrik.Listener

  require Logger

  alias Wardrik.Event.Log.Entry
  alias WardrikDefinition.Route
  alias WardrikNotify.Notice

  @attempts 3

  @impl Wardrik.Listener
  def handle(%Entry{log: agent} = entry, %Wardrik.Listener{options: opts} = listener) do
    host = Keyword.fetch!(opts, :host)

    with {:ok, %Wardrik.Definition{notify: %Route{} = route}} <-
           Wardrik.Definitions.get(Wardrik.Host.definitions(host), agent),
         {:ok, notice} <- Notice.from_entry(entry, host: host),
         true <- notice.kind in route.on do
      Enum.each(route.targets, &tell(&1, notice, opts, 1))
    end

    WardrikNotify.Keeper.saved(Keyword.fetch!(opts, :keeper), listener.cursor)
  end

  defp tell(name, notice, opts, attempt) do
    task =
      Task.Supervisor.async_nolink(Keyword.fetch!(opts, :tasks), fn ->
        deliver(name, notice, opts)
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> told(result, name, notice, opts, attempt)
      {:exit, reason} -> told({:error, {:crashed, reason}}, name, notice, opts, attempt)
    end
  end

  defp deliver(name, notice, opts) do
    targets = Keyword.fetch!(opts, :targets)

    with {:ok, {module, target}} <- WardrikNotify.target(targets, name),
         true <- WardrikNotify.tells?(targets, name, Wardrik.AgentAddress.agent(notice.agent).org) do
      target
      |> Keyword.put(:target, name)
      |> Keyword.put_new(:req_options, Keyword.fetch!(opts, :req_options))
      |> then(&module.deliver(notice, &1))
    else
      :error -> {:skip, "which config.yaml does not configure"}
      false -> {:skip, "which tells another org's agents"}
    end
  end

  defp told(:ok, _name, _notice, _opts, _attempt), do: :ok

  defp told({:skip, why}, name, notice, _opts, _attempt),
    do: Logger.warning("#{notice.agent} routes to #{name}, #{why}")

  defp told({:error, reason}, name, notice, opts, attempt) when attempt < @attempts do
    Logger.warning(failed(name, notice, reason) <> "; trying again")
    Process.sleep(Keyword.fetch!(opts, :backoff) * 2 ** (attempt - 1))
    tell(name, notice, opts, attempt + 1)
  end

  defp told({:error, reason}, name, notice, _opts, _attempt),
    do: Logger.warning(failed(name, notice, reason) <> "; giving up")

  defp failed(name, notice, reason),
    do: "Could not tell #{name} that #{notice.agent} #{notice.kind}: #{inspect(reason)}"
end
