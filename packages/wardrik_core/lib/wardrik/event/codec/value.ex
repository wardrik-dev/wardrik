defmodule Wardrik.Event.Codec.Value do
  @moduledoc """
  The values inside a CloudEvent's data, as JSON-ready maps with string keys.

  Messages take OpenTelemetry's GenAI shape: a role and a list of parts, each
  tagged by `type` (`text`, `reasoning`, `tool_call`, `tool_call_response`,
  `uri`, `file`, `blob`). Failures, tool results, usage and principals each
  have one shape, whatever Elixir term they came from.

  A tool's arguments or result, or a part's content, longer than
  #{64 * 1024} bytes once encoded is cut and marked `"truncated": true`.
  """

  alias Wardrik.Bus
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Blob
  alias Wardrik.Conversation.Reasoning
  alias Wardrik.Conversation.ServerToolCall
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolError
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.Uri
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Usage
  alias Wardrik.Principal
  alias Wardrik.Tool.Result

  @limit 64 * 1024

  @doc """
  A message of a `Wardrik.Conversation` as an OpenTelemetry message, under
  `id` where one is given. A tool's answer is named for its tool.
  """
  @spec message(Conversation.message(), String.t() | nil) :: map()
  def message(message, id \\ nil) do
    %{"role" => role(message), "parts" => parts(message)}
    |> put("id", id)
    |> put("name", Map.get(message, :name))
  end

  @doc "A message someone sent an agent, as an OpenTelemetry message."
  @spec user(Wardrik.Agent.Message.t()) :: map()
  def user(%Wardrik.Agent.Message{id: id, text: text}),
    do: %{"id" => id, "role" => "user", "parts" => [text_part("text", text)]}

  @doc "An assistant's answer of plain text, as an OpenTelemetry message."
  @spec assistant(String.t()) :: map()
  def assistant(text) when is_binary(text),
    do: %{"role" => "assistant", "parts" => [text_part("text", text)]}

  defp role(%User{}), do: "user"
  defp role(%Assistant{}), do: "assistant"
  defp role(%ToolResult{}), do: "tool"
  defp role(%ToolError{}), do: "tool"

  defp parts(%{call_id: id} = answer),
    do: [%{"type" => "tool_call_response", "id" => id, "response" => Conversation.text(answer)}]

  # The calls a model asked for follow what it said, as OpenTelemetry lists
  # them.
  defp parts(%{parts: parts}) do
    {calls, said} = Enum.split_with(parts, &call?/1)
    Enum.map(said, &part/1) ++ Enum.map(calls, &tool_call/1)
  end

  defp call?(%ToolCall{}), do: true
  defp call?(%ServerToolCall{}), do: true
  defp call?(_part), do: false

  defp part(%Text{text: text}), do: text_part("text", text)
  defp part(%Reasoning{text: text}), do: text_part("reasoning", text)

  defp part(%Uri{modality: modality, uri: uri}),
    do: %{"type" => "uri", "modality" => modality, "uri" => uri}

  defp part(%Wardrik.Conversation.File{file_id: id, mime_type: mime_type}),
    do:
      put(%{"type" => "file", "modality" => "document", "file_id" => id}, "mime_type", mime_type)

  defp part(%Blob{modality: modality, mime_type: mime_type, data: data}) do
    %{"type" => "blob", "modality" => modality}
    |> put("mime_type", mime_type)
    |> capped("content", Base.encode64(data))
  end

  defp text_part(type, text), do: capped(%{"type" => type}, "content", text)

  defp tool_call(%{id: id, name: name, arguments: arguments}),
    do: capped(%{"type" => "tool_call", "id" => id, "name" => name}, "arguments", json(arguments))

  @doc """
  A failure reason as `{type, message}`: `type` is its low-cardinality code,
  as OpenTelemetry's `error.type`, and `message` says what happened.
  """
  @spec error(term()) :: map()
  def error(reason) do
    {:ok, %{"error" => %{"code" => code, "message" => message}}} = Result.error(reason)
    %{"type" => code, "message" => message}
  end

  @doc """
  What a tool answered, as `{status, result, error}`: `"ok"` with what it
  returned, or `"error"` with why, whichever way the tool said it.
  """
  @spec result(term()) :: {String.t(), term(), map() | nil}
  def result({:ok, %{"ok" => false, "error" => %{"code" => code, "message" => message}}}),
    do: {"error", nil, %{"type" => code, "message" => message}}

  def result({:ok, %{"ok" => true, "result" => result}}), do: {"ok", json(result), nil}
  def result({:ok, result}), do: {"ok", json(result), nil}
  def result({:error, reason}), do: {"error", nil, error(reason)}
  def result(other), do: {"error", nil, error({:invalid_result, other})}

  @doc "What a model call used, as OpenTelemetry names it, without the `gen_ai.` prefix."
  @spec usage(Usage.t() | nil) :: map() | nil
  def usage(nil), do: nil

  def usage(%Usage{} = usage) do
    %{}
    |> put("input_tokens", usage.input_tokens)
    |> put("output_tokens", usage.output_tokens)
    |> put("cache_read", count("input_tokens", usage.cached_tokens))
    |> put("reasoning", count("output_tokens", usage.reasoning_tokens))
  end

  @doc "What a call cost, as `t:Wardrik.Call.cost/0` carries it, or `nil`."
  @spec cost(Wardrik.Call.cost() | nil) :: map() | nil
  def cost(nil), do: nil

  def cost(%{micro_usd: micro_usd, source: source}),
    do: %{"micro_usd" => micro_usd, "source" => Atom.to_string(source)}

  defp count(_key, nil), do: nil
  defp count(key, value), do: %{key => value}

  @doc """
  A call a run is waiting on a person for, with the prompt it was held with.
  A model call a dispatch held is not a tool call, and says so. A call waiting
  for a person to authorize is `authorization`, and carries no link, and one
  that may already have done what it does is `in_doubt`. `labels` are those
  of what the run had read, which may be what asked for the call.
  """
  @spec interrupt({Wardrik.Tool.call(), String.t()}) :: map()
  def interrupt({call, _prompt} = waiting),
    do: waiting |> interrupt_of() |> put("labels", Map.get(call, :labels))

  defp interrupt_of({%{id: id, name: "model"}, prompt}),
    do: %{"id" => id, "reason" => "model_approval", "message" => prompt}

  defp interrupt_of({%{in_doubt: true} = call, prompt}),
    do: tool_interrupt(call, "in_doubt", prompt)

  defp interrupt_of({%{link: %{url: _url}} = call, prompt}),
    do: tool_interrupt(call, "authorization", prompt)

  defp interrupt_of({call, prompt}), do: tool_interrupt(call, "tool_approval", prompt)

  defp tool_interrupt(%{id: id, name: name}, reason, prompt) do
    %{"id" => id, "reason" => reason, "message" => prompt, "tool_call_id" => id}
    |> put("name", name)
  end

  @doc """
  What an agent is doing, as `Wardrik.Agent.Activity` says: each thing it is
  doing as the type of the event that set it, with what that event names of
  it, and none when it is idle; since when; and how many messages wait.
  """
  @spec activity(Wardrik.Agent.Activity.t()) :: map()
  def activity(%Wardrik.Agent.Activity{} = activity) do
    %{
      "doing" => doing(activity.doing),
      "since" => activity.since |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      "pending" => activity.pending
    }
  end

  defp doing(:idle), do: []
  defp doing([_ | _] = calls), do: Enum.flat_map(calls, &doing/1)
  defp doing(%Bus.TurnStarted{}), do: [%{"type" => "wardrik.run.started"}]
  defp doing(%Bus.TurnResumed{}), do: [%{"type" => "wardrik.run.resumed"}]

  defp doing(%Bus.TurnParked{calls: calls}),
    do: [%{"type" => "wardrik.run.interrupted", "interrupts" => Enum.map(calls, &interrupt/1)}]

  defp doing(%Bus.ModelStarted{message_id: id}),
    do: [%{"type" => "wardrik.message.started", "message" => %{"id" => id}}]

  defp doing(%Bus.ModelRetrying{} = retry) do
    [
      %{
        "type" => "wardrik.message.retrying",
        "message" => %{"id" => retry.message_id},
        "attempt" => retry.attempt,
        "attempts" => retry.attempts,
        "wait_ms" => retry.wait_ms
      }
    ]
  end

  defp doing(%Bus.SpanStarted{name: name}),
    do: [%{"type" => "wardrik.step.started", "step" => %{"name" => name}}]

  defp doing(%Bus.ToolStarted{} = call), do: [tool("wardrik.tool_call.started", call)]
  defp doing(%Bus.ToolDenied{} = call), do: [tool("wardrik.tool_call.denied", call)]
  defp doing(%Bus.ToolFinished{} = call), do: [tool("wardrik.tool_call.completed", call)]
  defp doing(%Bus.ToolReplayed{} = call), do: [tool("wardrik.tool_call.completed", call)]

  defp tool(type, call),
    do: %{"type" => type, "tool" => %{"name" => call.name, "call" => %{"id" => call.call_id}}}

  @doc """
  The provider and model a model spec names, however it names them: as
  `"provider:model"`, a `{provider, options}` pair, or a model struct. The
  provider is `nil` where the spec does not say.
  """
  @spec model(term()) :: {String.t() | nil, String.t()}
  def model(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, model] -> {provider, model}
      [model] -> {nil, model}
    end
  end

  def model({provider, opts}) when is_atom(provider) and is_list(opts),
    do: {Atom.to_string(provider), to_string(opts[:model] || opts[:id])}

  def model(%{provider: provider, id: id}), do: {to_string(provider), to_string(id)}
  def model(spec), do: {nil, inspect(spec)}

  @doc "Who decided a call that went ahead or was refused; see `t:Wardrik.Call.decider/0`."
  @spec decided(Wardrik.Call.decider()) :: map()
  def decided(%{by: by, hooks: hooks}),
    do: put(%{"by" => Atom.to_string(by)}, "hooks", if(hooks != [], do: hooks))

  @doc "What answered a tool call, where its tool said; see `t:Wardrik.Call.served/0`."
  @spec served(Wardrik.Call.served() | nil) :: map() | nil
  def served(nil), do: nil
  def served(%{id: id} = served), do: put(%{"id" => id}, "name", Map.get(served, :name))

  @doc "Who decided something."
  @spec principal(Wardrik.Principal.t() | nil) :: map() | nil
  def principal(nil), do: nil

  def principal(principal) do
    put(%{"id" => Principal.id(principal)}, "name", Principal.name(principal))
  end

  @doc "Who acted for someone, first to last, or `nil` where nobody did."
  @spec principals([Wardrik.Principal.t()]) :: [map()] | nil
  def principals([]), do: nil
  def principals(principals), do: Enum.map(principals, &principal/1)

  @doc """
  `token`, never a secret: whom it acts for, what each of its statements
  allows on what, the policy it names, and when it expires, where it does.
  """
  @spec token(Wardrik.Token.t()) :: map()
  def token(%Wardrik.Token{} = token) do
    %{
      "principal" => principal(token.principal),
      "statements" =>
        for(
          statement <- token.scope,
          do: %{
            "actions" => statement.actions,
            "resources" => Enum.map(statement.resources, &to_string/1)
          }
        )
    }
    |> put("policy", if(token.policy != :none, do: token.policy))
    |> put("expires", expires(token.expires))
  end

  defp expires(:infinity), do: nil
  defp expires(at), do: DateTime.to_iso8601(at)

  @doc """
  A term as JSON can hold it: maps with string keys, lists, strings, numbers,
  booleans and `nil`. An atom becomes its name, a struct its fields, a tuple a
  list, and anything else, a pid or a function, how `inspect/1` shows it.
  """
  @spec json(term()) :: term()
  def json(value) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)

  def json(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  def json(value) when is_list(value), do: Enum.map(value, &json/1)
  def json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  def json(%_struct{} = value), do: value |> Map.from_struct() |> json()
  def json(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), json(v)} end)
  def json(value), do: inspect(value)

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)

  @doc """
  Puts `value` under `key` in `map`, cut to #{@limit} bytes once encoded with
  `"truncated": true` beside it when it is longer.
  """
  @spec capped(map(), String.t(), term()) :: map()
  def capped(map, key, value) when is_binary(value) and byte_size(value) > @limit,
    do: map |> Map.put(key, whole(binary_part(value, 0, @limit))) |> Map.put("truncated", true)

  def capped(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  def capped(map, key, value) do
    encoded = JSON.encode!(value)

    if byte_size(encoded) > @limit,
      do:
        map
        |> Map.put(key, %{"preview" => whole(binary_part(encoded, 0, @limit))})
        |> Map.put("truncated", true),
      else: Map.put(map, key, value)
  end

  # A cut lands mid-character often enough, and what is sent must be valid UTF-8.
  defp whole(""), do: ""

  defp whole(text),
    do: if(String.valid?(text), do: text, else: whole(binary_part(text, 0, byte_size(text) - 1)))

  @doc "Puts `value` under `key`, unless it is `nil`."
  @spec put(map(), String.t(), term()) :: map()
  def put(map, _key, nil), do: map
  def put(map, key, value), do: Map.put(map, key, value)
end
