defmodule WardrikNotify.Listener do
  @moduledoc """
  The `Wardrik.Listener` `WardrikNotify.Keeper` runs: for each turn an
  agent parked, failed or finished, it reads where the agent's notices go
  from its definition, `WardrikDefinition.Route`, as the event comes, and
  hands the `WardrikNotify.Notice` the route asks for to each of its
  targets and rooms in turn, as `WardrikNotify.Destination` delivers to
  it. Then it hands the keeper the cursor past the event.

  An agent's route is read from the definition kept for it, by its ID, so
  a `Wardrik.Thread` of it, as `acme/books/1696.1234`, which has no
  definition of its own, is routed nowhere.

  Each delivery runs in a task of its own under `:tasks`, so a target that
  crashes is taken as one that failed: it is tried again after `:backoff`,
  then after twice that, and given up with a warning after the third
  attempt. A target `config.yaml` does not configure, or that does not tell
  the agent's org, is not tried again, nor a room with no workspace of the
  agent's owner to post in. The next event waits for the targets of the
  one before.

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
      Enum.each(route.targets ++ route.rooms, &tell(&1, notice, opts, 1))
    end

    WardrikNotify.Keeper.saved(Keyword.fetch!(opts, :keeper), listener.cursor)
  end

  defp tell(name, notice, opts, attempt) do
    task =
      Task.Supervisor.async_nolink(Keyword.fetch!(opts, :tasks), fn ->
        WardrikNotify.Destination.deliver(name, notice, opts)
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> told(result, name, notice, opts, attempt)
      {:exit, reason} -> told({:error, {:crashed, reason}}, name, notice, opts, attempt)
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
