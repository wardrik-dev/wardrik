defmodule WardrikCore.Agent.Stored do
  @moduledoc false

  # An agent's state as it's kept: its conversation, queue and model, and the turn a restart
  # carries on. How it's configured isn't kept; it's given again as the agent loads.
  #
  # Its private data, checkpoint and parked turn may hold values of its middleware's formats, so
  # they're read once its configuration names them. Until then they're kept as they were read.

  alias WardrikCore.Agent.State
  alias WardrikCore.Context
  alias WardrikCore.Span
  alias WardrikCore.Stored.Message
  alias WardrikCore.Stored.Term
  alias WardrikCore.ToolCall
  alias WardrikCore.ToolRunner

  @core [WardrikCore.Authorization, WardrikCore.Retry.Exhausted]
  @deferred ["private", "checkpoint", "parked"]
  @states %{"idle" => :idle, "due" => :due, "waiting" => :waiting}

  # What reading JSON of an unexpected shape raises.
  @malformed [
    ArgumentError,
    BadMapError,
    CaseClauseError,
    FunctionClauseError,
    KeyError,
    MatchError,
    Protocol.UndefinedError
  ]

  @doc "Returns the state as JSON. A state not yet read in full is kept as it was read."
  @spec dump(State.t()) :: map()
  def dump(%State{unreadable: {_reason, json}}), do: json

  def dump(%State{} = state) do
    kept = requeued(state)

    core = %{
      "agent_id" => state.agent_id,
      "conversation" => state.conversation,
      "model" => state.model,
      "state" => Atom.to_string(kept.state),
      "messages" => Message.dump(state.messages),
      "pending" => Message.dump(kept.pending_messages),
      "in_flight" => Message.dump(kept.in_flight)
    }

    Map.merge(core, deferred(state))
  end

  defp deferred(%State{deferred: %{} = json}), do: Map.take(json, @deferred)

  defp deferred(%State{} = state) do
    %{
      "private" => private(state.context.private),
      "checkpoint" => state.checkpoint && checkpoint(state.checkpoint),
      "parked" => state.parked && parked(state.parked)
    }
  end

  defp requeued(%State{state: :running, checkpoint: %{}} = state), do: %{state | state: :due}
  defp requeued(%State{state: :running, parked: %{}} = state), do: %{state | state: :waiting}

  defp requeued(%State{state: :running} = state),
    do: %{
      state
      | state: :idle,
        in_flight: [],
        pending_messages: state.in_flight ++ state.pending_messages
    }

  defp requeued(state), do: state

  @doc """
  Reads a kept state, all but what waits on its middleware's formats. A state that can't be read
  is kept as it was, with why.
  """
  @spec load(term()) :: State.t()
  def load(%{"agent_id" => agent_id} = json) do
    %State{
      agent_id: agent_id,
      conversation: json["conversation"],
      model: json["model"],
      state: Map.fetch!(@states, json["state"]),
      messages: Message.loaded(json["messages"]),
      pending_messages: Message.loaded(json["pending"]),
      in_flight: Message.loaded(json["in_flight"]),
      deferred: json
    }
  rescue
    error in @malformed -> unreadable(json, malformed(error))
  catch
    {:unreadable, reason} -> unreadable(json, reason)
  end

  def load(json), do: unreadable(json, "it isn't an agent's state")

  @doc """
  Reads what waited on the formats of `state`'s configured middleware and capabilities. A
  state that can't be read is kept as it was, with why.
  """
  @spec resolve(State.t()) :: State.t()
  def resolve(%State{deferred: nil} = state), do: state

  def resolve(%State{deferred: json, context: %Context{} = context} = state) do
    formats = formats(context)

    %{
      state
      | deferred: nil,
        context: %{context | private: read_private(json["private"], formats)},
        checkpoint: json["checkpoint"] && read_checkpoint(json["checkpoint"], formats),
        parked: json["parked"] && read_parked(json["parked"], formats)
    }
  rescue
    error in @malformed -> unreadable(json, malformed(error))
  catch
    {:unreadable, reason} -> unreadable(json, reason)
  end

  # Whatever a saved state holds, reading it never stops the agent, let alone others.
  defp unreadable(json, reason) when is_map(json),
    do: %State{
      agent_id: json["agent_id"],
      conversation: json["conversation"],
      unreadable: {reason, json}
    }

  defp unreadable(json, reason), do: %State{unreadable: {reason, json}}

  defp malformed(error),
    do: "it isn't in a form this release can read: #{Exception.message(error)}"

  @doc """
  Returns why the agent can't keep `reason` to wait on, or `nil`. It keeps what its formats can
  read back.
  """
  @spec unkept(term(), Context.t()) :: String.t() | nil
  def unkept(reason, %Context{} = context) do
    formats = formats(context)
    unkept_reason(reason, formats)
  catch
    {:unreadable, why} -> why
  end

  defp unkept_reason(:in_doubt, _formats), do: nil

  defp unkept_reason({:tool_calls, results}, formats),
    do: Enum.find_value(results, fn {_call, outcome} -> unkept_outcome(outcome, formats) end)

  defp unkept_reason(%format{}, formats) do
    if typed?(format) and Map.get(formats, format.type()) == format,
      do: nil,
      else: "it can't keep #{inspect(format)}: none of its middleware or capabilities lists it"
  end

  defp unkept_reason(reason, _formats),
    do: "it can't keep #{inspect(reason)}: a reason to wait on needs a format"

  defp unkept_outcome({:park, reason}, formats), do: unkept_reason(reason, formats)
  defp unkept_outcome(_outcome, _formats), do: nil

  @doc "Returns `private` without the values it can't keep, those not under a format's key."
  @spec keepable(map()) :: {map(), [term()]}
  def keepable(private) do
    {kept, dropped} = Enum.split_with(private, fn {key, _value} -> typed?(key) end)
    {Map.new(kept), Enum.map(dropped, &elem(&1, 0))}
  end

  defp typed?(format),
    do: is_atom(format) and Code.ensure_loaded?(format) and function_exported?(format, :type, 0)

  @doc "Returns the formats `context`'s middleware and capabilities keep values in, by type."
  @spec formats(Context.t()) :: %{String.t() => module()}
  def formats(%Context{} = context) do
    declared =
      for entry <- context.middleware ++ context.capabilities,
          {module, _opts} = Context.entry(entry),
          Code.ensure_loaded?(module),
          function_exported?(module, :formats, 0),
          format <- module.formats(),
          do: format

    (@core ++ declared)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn format, formats ->
      type = typed?(format) && format.type()

      cond do
        !type -> throw({:unreadable, "#{inspect(format)} is listed as a format without a type"})
        Map.has_key?(formats, type) -> throw({:unreadable, both(format, formats[type], type)})
        true -> Map.put(formats, type, format)
      end
    end)
  end

  defp private(private) do
    Map.new(private, fn {format, value} -> {type!(format), typed(format, value)} end)
  end

  defp read_private(private, formats),
    do: Map.new(private, fn {type, value} -> read_typed(type, value, formats) end)

  defp checkpoint(checkpoint) do
    %{
      "messages" => Message.dump(checkpoint.messages),
      "calls" => Enum.map(checkpoint.calls, &call/1),
      "rounds" => rounds(checkpoint.rounds),
      "private" => private(checkpoint.private),
      "span" => span(checkpoint.span),
      "measurements" => measurements(checkpoint.measurements)
    }
  end

  defp read_checkpoint(checkpoint, formats) do
    %{
      messages: Message.loaded(checkpoint["messages"]),
      calls: Enum.map(checkpoint["calls"], &read_call/1),
      rounds: read_rounds(checkpoint["rounds"]),
      metadata: %{},
      private: read_private(checkpoint["private"], formats),
      span: read_span(checkpoint["span"]),
      measurements: read_measurements(checkpoint["measurements"])
    }
  end

  defp parked(parked) do
    %{
      "reason" => reason(parked.reason),
      "messages" => Message.dump(parked.messages),
      "span" => span(parked.span),
      "measurements" => measurements(parked.measurements)
    }
  end

  defp read_parked(parked, formats) do
    %{
      reason: read_reason(parked["reason"], formats),
      messages: Message.loaded(parked["messages"]),
      metadata: %{},
      span: read_span(parked["span"]),
      measurements: read_measurements(parked["measurements"])
    }
  end

  defp reason(:in_doubt), do: %{"type" => "in_doubt"}

  defp reason({:tool_calls, results}) do
    %{
      "type" => "tool_calls",
      "calls" =>
        for(
          {call, outcome} <- results,
          do: %{"call" => call(call), "outcome" => outcome(outcome)}
        )
    }
  end

  defp reason(%format{} = reason) do
    typed = typed(format, reason)
    Map.put(typed, "type", type!(format))
  end

  defp reason(reason),
    do: raise(ArgumentError, "an agent can't park on #{inspect(reason)}: give it a format")

  defp read_reason(%{"type" => "in_doubt"}, _formats), do: :in_doubt

  defp read_reason(%{"type" => "tool_calls", "calls" => calls}, formats),
    do:
      {:tool_calls,
       for(
         %{"call" => call, "outcome" => outcome} <- calls,
         do: {read_call(call), read_outcome(outcome, formats)}
       )}

  defp read_reason(%{"type" => type} = reason, formats) do
    {_type, value} = read_typed(type, reason, formats)
    value
  end

  # What a call answered is kept as the model is shown it.
  defp outcome({:park, reason}), do: %{"park" => reason(reason)}
  defp outcome({:ok, output}), do: %{"ok" => output(output)}

  defp outcome({:error, %ReqLLM.ToolResult{output: reason} = result}),
    do: %{"error" => output(%{result | output: ToolRunner.message(reason)})}

  defp outcome({:error, reason}), do: %{"error" => %{"text" => ToolRunner.message(reason)}}

  defp read_outcome(%{"park" => reason}, formats), do: {:park, read_reason(reason, formats)}
  defp read_outcome(%{"ok" => output}, _formats), do: {:ok, read_output(output)}
  defp read_outcome(%{"error" => output}, _formats), do: {:error, read_output(output)}

  defp output(%ReqLLM.ToolResult{} = result) do
    %{
      "result" => %{
        "content" => result.content && Enum.map(result.content, &Message.part/1),
        "output" => shown(result.output),
        "metadata" => Term.dump(result.metadata)
      }
    }
  end

  defp output(text) when is_binary(text), do: %{"text" => text}

  defp output([%ReqLLM.Message.ContentPart{} | _parts] = parts),
    do: %{"parts" => Enum.map(parts, &Message.part/1)}

  defp output(output), do: %{"json" => shown(output)}

  defp read_output(%{"result" => result}) do
    %ReqLLM.ToolResult{
      content: result["content"] && Enum.map(result["content"], &Message.read_part/1),
      output: result["output"],
      metadata: Term.loaded(result["metadata"])
    }
  end

  defp read_output(%{"text" => text}), do: text
  defp read_output(%{"parts" => parts}), do: Enum.map(parts, &Message.read_part/1)
  defp read_output(%{"json" => json}), do: json

  defp shown(output) do
    output
    |> JSON.encode!()
    |> JSON.decode!()
  rescue
    _not_json in [Protocol.UndefinedError, ArgumentError] -> inspect(output)
  end

  defp typed(format, value),
    do: %{"version" => format.version(), "value" => format.dump(value)}

  defp read_typed(type, %{"version" => version, "value" => value}, formats) do
    format = Map.get(formats, type) || throw({:unreadable, unknown(type)})

    if version > format.version(),
      do: throw({:unreadable, "a later release kept its #{type} at version #{version}"})

    case format.load(version, value) do
      {:ok, loaded} -> {format, loaded}
      {:error, reason} -> throw({:unreadable, "its #{type} can't be read: #{reason}"})
    end
  end

  defp both(format, other, type),
    do: "#{inspect(format)} and #{inspect(other)} are both #{type}, so neither can be read"

  defp unknown(type), do: "it holds a #{type}, which none of its middleware or capabilities reads"

  defp type!(format) do
    if Code.ensure_loaded?(format) and function_exported?(format, :type, 0),
      do: format.type(),
      else:
        raise(
          ArgumentError,
          "#{inspect(format)} keeps a value without a type: see WardrikCore.Format"
        )
  end

  defp call(%ToolCall{} = call), do: ToolCall.dump(call)

  defp read_call(call) do
    case ToolCall.load(1, call) do
      {:ok, call} -> call
      {:error, reason} -> throw({:unreadable, reason})
    end
  end

  defp rounds(:infinity), do: "infinity"
  defp rounds(rounds), do: rounds

  defp read_rounds("infinity"), do: :infinity
  defp read_rounds(rounds), do: rounds

  defp span(nil), do: nil

  defp span(%Span{} = span),
    do: %{"id" => span.id, "trace" => span.trace, "parent" => span.parent}

  defp read_span(nil), do: nil

  defp read_span(%{"id" => id, "trace" => trace, "parent" => parent}),
    do: %Span{id: id, trace: trace, parent: parent}

  defp measurements(measurements),
    do:
      Map.new(measurements, fn {key, amount} when is_atom(key) ->
        {Atom.to_string(key), amount}
      end)

  defp read_measurements(measurements),
    do: Map.new(measurements, fn {key, amount} -> {Term.atom!(key), amount} end)
end
