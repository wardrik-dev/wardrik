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

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall
  alias Wardrik.Principal
  alias Wardrik.Tool.Result

  @limit 64 * 1024

  @doc "A `ReqLLM.Message` as an OpenTelemetry message, under `id` where one is given."
  @spec message(ReqLLM.Message.t(), String.t() | nil) :: map()
  def message(%ReqLLM.Message{} = message, id \\ nil) do
    %{"role" => to_string(message.role), "parts" => parts(message)}
    |> put("id", id)
    |> put("name", message.name)
  end

  @doc "A message someone sent an agent, as an OpenTelemetry message."
  @spec user(Wardrik.Agent.Message.t()) :: map()
  def user(%Wardrik.Agent.Message{id: id, text: text}),
    do: %{"id" => id, "role" => "user", "parts" => [text_part("text", text)]}

  @doc "An assistant's answer of plain text, as an OpenTelemetry message."
  @spec assistant(String.t()) :: map()
  def assistant(text) when is_binary(text),
    do: %{"role" => "assistant", "parts" => [text_part("text", text)]}

  defp parts(%ReqLLM.Message{role: :tool, tool_call_id: id} = message) when is_binary(id),
    do: [%{"type" => "tool_call_response", "id" => id, "response" => text(message.content)}]

  defp parts(%ReqLLM.Message{content: content, tool_calls: calls}),
    do: Enum.map(content(content), &part/1) ++ Enum.map(calls || [], &tool_call/1)

  defp content(text) when is_binary(text), do: [ContentPart.text(text)]
  defp content(parts) when is_list(parts), do: parts

  defp text(content) do
    content
    |> content()
    |> Enum.map_join(fn
      %ContentPart{text: text} when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp part(%ContentPart{type: :text, text: text}), do: text_part("text", text || "")
  defp part(%ContentPart{type: :thinking, text: text}), do: text_part("reasoning", text || "")
  defp part(%ContentPart{type: :image_url, url: url}), do: uri("image", url)
  defp part(%ContentPart{type: :video_url, url: url}), do: uri("video", url)

  defp part(%ContentPart{type: :file, file_id: id} = part) when is_binary(id),
    do:
      put(
        %{"type" => "file", "modality" => "document", "file_id" => id},
        "mime_type",
        part.media_type
      )

  defp part(%ContentPart{type: type, data: data} = part) when type in [:image, :file] do
    modality = if type == :image, do: "image", else: "document"

    %{"type" => "blob", "modality" => modality}
    |> put("mime_type", part.media_type)
    |> capped("content", Base.encode64(data || ""))
  end

  defp part(%ContentPart{type: type}), do: %{"type" => to_string(type)}

  defp text_part(type, text), do: capped(%{"type" => type}, "content", text)

  defp uri(modality, url), do: %{"type" => "uri", "modality" => modality, "uri" => url}

  defp tool_call(%ToolCall{} = call) do
    arguments =
      case ToolCall.args_map(call) do
        arguments when is_map(arguments) -> arguments
        _unreadable -> ToolCall.args_json(call)
      end

    capped(
      %{"type" => "tool_call", "id" => call.id, "name" => ToolCall.name(call)},
      "arguments",
      json(arguments)
    )
  end

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

  @doc "A provider's usage as OpenTelemetry names it, without the `gen_ai.` prefix."
  @spec usage(map() | nil) :: map() | nil
  def usage(nil), do: nil

  def usage(usage) when is_map(usage) do
    %{}
    |> put("input_tokens", usage[:input_tokens])
    |> put("output_tokens", usage[:output_tokens])
    |> put("cache_read", count("input_tokens", usage[:cached_tokens]))
    |> put("reasoning", count("output_tokens", usage[:reasoning_tokens]))
    |> put("cost_usd", usage[:total_cost])
  end

  defp count(_key, nil), do: nil
  defp count(key, value), do: %{key => value}

  @doc """
  A call a run is waiting on a person for, with the prompt it was held with.
  A model call a dispatch held is not a tool call, and says so. A call waiting
  for a person to authorize is `authorization`, and carries no link, and one
  that may already have done what it does is `in_doubt`.
  """
  @spec interrupt({Wardrik.Tool.call(), String.t()}) :: map()
  def interrupt({call, _prompt} = waiting),
    do: waiting |> interrupt_of() |> put("outside_content", if(Map.get(call, :outside), do: true))

  defp interrupt_of({%{id: id, name: "model"}, prompt}),
    do: %{"id" => id, "reason" => "model_approval", "message" => prompt}

  defp interrupt_of({%{id: id, in_doubt: true}, prompt}),
    do: %{"id" => id, "reason" => "in_doubt", "message" => prompt, "tool_call_id" => id}

  defp interrupt_of({%{id: id, link: %{url: _url}}, prompt}),
    do: %{"id" => id, "reason" => "authorization", "message" => prompt, "tool_call_id" => id}

  defp interrupt_of({%{id: id}, prompt}),
    do: %{"id" => id, "reason" => "tool_approval", "message" => prompt, "tool_call_id" => id}

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
    %{"type" => to_string(Principal.type(principal)), "id" => Principal.id(principal)}
    |> put("name", Principal.name(principal))
  end

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
