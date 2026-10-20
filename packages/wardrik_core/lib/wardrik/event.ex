defmodule Wardrik.Event do
  @moduledoc """
  Something an agent did, or a change someone made, as a struct to match on.

  Each type of event has a struct of its own: `Wardrik.Event.RunCompleted`
  for `wardrik.run.completed`, `Wardrik.Event.MessageDelta` for
  `wardrik.message.delta`, and so on. Your instance's `subscribe` sends
  them to your process as plain messages, so a LiveView matches the ones it
  shows:

      defmodule MyAppWeb.SupportLive do
        use MyAppWeb, :live_view

        def mount(_params, _session, socket) do
          :ok = MyApp.Agents.subscribe(socket.assigns.current_user, "support")
          {:ok, assign(socket, text: "", done: false)}
        end

        def handle_info(%Wardrik.Event.MessageDelta{delta: delta}, socket),
          do: {:noreply, update(socket, :text, &(&1 <> delta))}

        def handle_info(%Wardrik.Event.RunCompleted{}, socket),
          do: {:noreply, assign(socket, done: true)}

        def handle_info(_event, socket), do: {:noreply, socket}
      end

  Notice the last clause: an agent writes more kinds of event than a page
  shows.

  A struct's fields are the event's data, named as the protocol's schema
  for its type names them. A value that is an object stays a map with
  string keys. Every struct also has:

    * `id` - the event's id; a reader handed an event twice drops the
      repeat by it
    * `source` - the agent that wrote it, or `:audit` for a change someone
      made
    * `time` - when it happened, as a `DateTime`
    * `trace` - the id of the trace it is part of, which is the run's id
      for what a run did
    * `cursor` - where `events` reads on from after it, as its `after:`;
      none for a change in the audit
    * `cloudevent` - the whole event, as the HTTP API sends it

  `events` streams them, and `audit` answers the changes as them too.
  """

  alias Wardrik.Event.Cursor
  alias Wardrik.Event.Log.Entry

  @envelope [:id, :source, :time, :trace, :cursor, :cloudevent]
  @glob "../../priv/v1" |> Path.expand(__DIR__) |> Path.join("*.json")
  @files @glob |> Path.wildcard() |> Enum.sort()

  types =
    for file <- @files,
        %{"title" => "wardrik." <> name = type} = schema <- [:json.decode(File.read!(file))] do
      @external_resource file
      module = Module.concat(__MODULE__, Macro.camelize(String.replace(name, ".", "_")))
      fields = schema |> Map.get("properties", %{}) |> Map.keys() |> Enum.sort()
      fields = Enum.map(fields, &String.to_atom/1)

      if clash = Enum.find(fields, &(&1 in @envelope)),
        do: raise(CompileError, description: "#{type}'s data has #{clash}, which every event has")

      contents =
        quote do
          @moduledoc """
          `#{unquote(type)}`: #{unquote(schema["description"])}

          Its fields are its data's, and those `Wardrik.Event` says every
          event has.
          """

          defstruct unquote(@envelope ++ fields)

          @type t() :: %__MODULE__{}
        end

      Module.create(module, contents, Macro.Env.location(__ENV__))
      {type, module}
    end

  @modules Map.new(types)

  @typedoc "Any of the event structs, each named for its type."
  @type t() ::
          unquote(
            types
            |> Enum.map(fn {_type, module} -> quote(do: unquote(module).t()) end)
            |> Enum.reduce(&quote(do: unquote(&1) | unquote(&2)))
          )

  @doc """
  The struct of a log `entry`'s event, with the cursor past it moved from
  `cursor`, as `Wardrik.events/2` hands each on. With no cursor, it names
  the entry's log alone. An entry of the audit has no cursor.
  """
  @spec decode(Entry.t(), String.t() | :head) :: t()
  def decode(%Entry{log: log, event: %{"type" => type} = event} = entry, cursor \\ "") do
    data =
      for {key, value} <- Map.get(event, "data", %{}), do: {String.to_existing_atom(key), value}

    struct!(
      Map.fetch!(@modules, type),
      [
        id: event["id"],
        source: log,
        time: time(event["time"]),
        trace: trace(event["traceparent"]),
        cursor: past(cursor, entry),
        cloudevent: event
      ] ++ data
    )
  end

  @doc "The CloudEvent type of each struct, as `\"wardrik.run.completed\"`."
  @spec types() :: [String.t()]
  def types, do: Map.keys(@modules)

  # Compiles again when a schema is added or removed, as well as changed.
  @doc false
  def __mix_recompile__?, do: @glob |> Path.wildcard() |> Enum.sort() != @files

  defp past(_cursor, %Entry{log: :audit}), do: nil
  defp past(cursor, entry), do: Cursor.past(cursor, entry)

  defp time(time) do
    {:ok, time, _offset} = DateTime.from_iso8601(time)
    time
  end

  defp trace("00-" <> <<trace::binary-size(32), "-", _rest::binary>>), do: trace
end
