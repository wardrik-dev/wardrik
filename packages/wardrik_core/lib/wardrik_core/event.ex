defmodule WardrikCore.Event do
  @moduledoc """
  Something that happened to an agent.

  Each event goes to `:telemetry` and to the agent's `WardrikCore.Events` module. See
  `WardrikCore.Telemetry` for core's events. Packages emit their own:

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
  Emits an event to telemetry, and to the events module of `source`.

  `source` is a `WardrikCore.Context`, an events module as `module` or `{module, opts}`, or `nil`
  for telemetry only.
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
