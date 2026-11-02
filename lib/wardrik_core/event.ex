defmodule WardrikCore.Event do
  @moduledoc """
  Something that happened to an agent.

  Each event goes to two places:

    * `:telemetry`, for metrics and traces. Handlers run in the emitting process, and `:telemetry`
      detaches a handler that raises.
    * The agent's `WardrikCore.Events` sink, for clients that follow the agent, such as a CLI, a
      TUI or a web page.

  An event has a telemetry `name`, such as `[:wardrik_core, :turn, :stop]`, `measurements` and
  `metadata`. See `WardrikCore.Telemetry` for core's events. Packages emit their own the same way:

      WardrikCore.Event.emit(context, [:my_package, :refused], %{}, %{call: call})
  """
  alias WardrikCore.Context

  @enforce_keys [:name, :time]
  defstruct [:name, :time, measurements: %{}, metadata: %{}]

  @type t() :: %__MODULE__{
          name: [atom()],
          time: DateTime.t(),
          measurements: map(),
          metadata: map()
        }

  @doc """
  Emits an event to telemetry and to a sink.

  `source` is one of:

    * a `WardrikCore.Context` - emits to the agent's sink.
    * a sink, as `module` or `{module, opts}`.
    * `nil` - emits to telemetry only.
  """
  @spec emit(Context.t() | Context.entry() | nil, [atom()], map(), map()) :: :ok
  def emit(source, name, measurements \\ %{}, metadata) do
    metadata = conversation(source, metadata)
    :telemetry.execute(name, measurements, metadata)

    source
    |> sink()
    |> deliver(%__MODULE__{
      name: name,
      time: DateTime.utc_now(),
      measurements: measurements,
      metadata: metadata
    })
  end

  defp conversation(%Context{conversation: conversation}, metadata),
    do: Map.put_new(metadata, :conversation, conversation)

  defp conversation(_source, metadata), do: metadata

  defp sink(%Context{events: events}), do: events
  defp sink(events), do: events

  defp deliver(nil, _event), do: :ok

  defp deliver(sink, event) do
    {module, opts} = Context.entry(sink)
    module.handle_event(event, opts)
    :ok
  end
end
