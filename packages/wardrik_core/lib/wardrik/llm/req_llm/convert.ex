defmodule Wardrik.LLM.ReqLLM.Convert do
  @moduledoc """
  Wardrik's conversation values as ReqLLM's, and back, for
  `Wardrik.LLM.ReqLLM`, so that nothing beyond it reads a ReqLLM struct.

  A conversation goes to ReqLLM and back losing nothing: what a provider
  attached to a message, its parts or its tool calls, such as the signature
  of a model's reasoning, is kept in the `provider` maps of the conversation
  it comes back as, and sent again with it. An assistant's keeps its
  message's metadata as `"metadata"`, its reasoning details as
  `"reasoning_details"`, its tool calls' metadata by their ids as
  `"tool_calls"`, and what its other parts carry by their place as
  `"parts"`; a reasoning part keeps its own, and a tool result its
  message's. What a person's message carries besides its parts is not kept,
  as Wardrik makes those from text alone.

  Provider data is kept without naming any of ReqLLM's atoms, so an agent's
  stored history reads back on a node that has yet to load ReqLLM: an atom
  is kept as its name, a tuple as its elements and a struct as its fields,
  each tagged. They come back once ReqLLM's modules are loaded, as they are
  before a conversation is sent.
  """

  alias ReqLLM.Message.ContentPart
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
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Tools
  alias Wardrik.LLM.Usage

  @finish_reasons [
    :stop,
    :length,
    :tool_calls,
    :content_filter,
    :error,
    :cancelled,
    :incomplete,
    :unknown
  ]

  @evaluation_opts [
    :api_key,
    :base_url,
    :receive_timeout,
    :total_timeout,
    :max_retries,
    :req_http_options,
    :fixture,
    :telemetry
  ]

  # -- to ReqLLM ----------------------------------------------------------------

  @doc "A conversation, or one of its messages, as ReqLLM's."
  @spec to_req_llm(Conversation.t()) :: ReqLLM.Context.t()
  @spec to_req_llm(Conversation.message()) :: ReqLLM.Message.t()
  def to_req_llm(%Conversation{messages: messages}) do
    _loaded = Code.ensure_all_loaded(Application.spec(:req_llm, :modules))
    ReqLLM.Context.new(Enum.map(messages, &to_req_llm/1))
  end

  def to_req_llm(%User{parts: parts}),
    do: %ReqLLM.Message{role: :user, content: Enum.map(parts, &content_part(&1, %{}))}

  def to_req_llm(%Assistant{parts: parts, provider: provider}) do
    kept = restored(provider)
    placed = Map.get(kept, "parts", %{})

    {calls, content} =
      parts
      |> Enum.with_index()
      |> Enum.split_with(fn {part, _at} -> call?(part) end)

    %ReqLLM.Message{
      role: :assistant,
      name: kept["name"],
      content:
        Enum.map(content, fn {part, at} -> content_part(part, Map.get(placed, at, %{})) end),
      tool_calls: tool_calls(calls, Map.get(kept, "tool_calls", %{})),
      metadata: Map.get(kept, "metadata", %{}),
      reasoning_details: kept["reasoning_details"]
    }
  end

  def to_req_llm(%ToolResult{} = result), do: tool_message(result, metadata(result))

  def to_req_llm(%ToolError{} = error),
    do: tool_message(error, Map.put(metadata(error), :is_error, true))

  defp metadata(%{provider: provider}), do: provider |> restored() |> Map.get("metadata", %{})

  defp tool_message(%{call_id: id, name: name, parts: parts}, metadata) do
    %ReqLLM.Message{
      role: :tool,
      name: name,
      tool_call_id: id,
      content: Enum.map(parts, &content_part(&1, %{})),
      metadata: metadata
    }
  end

  defp call?(%ToolCall{}), do: true
  defp call?(%ServerToolCall{}), do: true
  defp call?(_part), do: false

  defp content_part(%Text{text: text}, placed), do: placed(ContentPart.text(text), placed)

  defp content_part(%Reasoning{text: text, provider: provider}, _placed),
    do: ContentPart.thinking(text, Map.get(restored(provider), "metadata", %{}))

  defp content_part(%Uri{modality: "image", uri: uri}, placed),
    do: placed(ContentPart.image_url(uri), placed)

  defp content_part(%Uri{modality: "video", uri: uri}, placed),
    do: placed(ContentPart.video_url(uri), placed)

  defp content_part(%Wardrik.Conversation.File{} = file, placed),
    do:
      placed(%ContentPart{type: :file, file_id: file.file_id, media_type: file.mime_type}, placed)

  defp content_part(%Blob{modality: "image"} = blob, placed),
    do: placed(%ContentPart{type: :image, data: blob.data, media_type: blob.mime_type}, placed)

  defp content_part(%Blob{modality: "document"} = blob, placed),
    do: placed(%ContentPart{type: :file, data: blob.data, media_type: blob.mime_type}, placed)

  defp placed(part, placed),
    do: %{part | metadata: Map.get(placed, "metadata", %{}), filename: placed["filename"]}

  defp tool_calls([], _kept), do: nil

  defp tool_calls(calls, kept) do
    for {call, _at} <- calls do
      call
      |> made()
      |> ReqLLM.ToolCall.put_metadata(Map.get(kept, call.id, %{}))
    end
  end

  defp made(%ToolCall{id: id, name: name, arguments: arguments}),
    do: ReqLLM.ToolCall.new(id, name, json(arguments))

  defp made(%ServerToolCall{id: id, name: name, arguments: arguments}),
    do: ReqLLM.ToolCall.new_builtin(id, name, json(arguments))

  defp json(arguments) when is_binary(arguments), do: arguments
  defp json(arguments), do: JSON.encode!(arguments)

  @doc """
  The options of a request as ReqLLM takes them: its tools, which are
  `Wardrik.Tool`s, as `ReqLLM.Tool`s.
  """
  @spec opts(keyword()) :: keyword()
  def opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} -> Keyword.put(opts, :tools, Enum.map(tools, &Tools.to_req_llm/1))
      :error -> opts
    end
  end

  @doc "The options of a request that `ReqLLM.evaluate/4` takes, without those it refuses."
  @spec evaluation_opts(keyword()) :: keyword()
  def evaluation_opts(opts) when is_list(opts), do: Keyword.take(opts, @evaluation_opts)

  @doc "`usage` as ReqLLM prices it: the counts it holds, without those it has none for."
  @spec usage_map(Usage.t()) :: map()
  def usage_map(%Usage{} = usage),
    do: usage |> Map.from_struct() |> Map.reject(fn {_key, value} -> is_nil(value) end)

  # -- from ReqLLM ----------------------------------------------------------------

  @doc "A ReqLLM context, or one of its messages, as Wardrik's."
  @spec from_req_llm(ReqLLM.Context.t()) :: Conversation.t()
  @spec from_req_llm(ReqLLM.Message.t()) :: Conversation.message()
  def from_req_llm(%ReqLLM.Context{messages: messages}),
    do: Conversation.new(Enum.map(messages, &from_req_llm/1))

  def from_req_llm(%ReqLLM.Message{role: :user, content: content}),
    do: %User{parts: content |> contents() |> Enum.map(&part/1)}

  def from_req_llm(%ReqLLM.Message{role: :assistant} = message) do
    parts = message.content |> contents() |> Enum.map(&part/1)
    calls = message.tool_calls || []

    provider =
      %{}
      |> put("name", message.name)
      |> put("metadata", kept(message.metadata))
      |> put("reasoning_details", kept(message.reasoning_details))
      |> put("parts", placed(message.content))
      |> put("tool_calls", calls_metadata(calls))

    %Assistant{parts: parts ++ Enum.map(calls, &call/1), provider: provider}
  end

  def from_req_llm(%ReqLLM.Message{role: :tool, metadata: metadata} = message) do
    {error?, metadata} = Map.pop(metadata, :is_error, false)

    fields = %{
      call_id: message.tool_call_id,
      name: message.name,
      parts: message.content |> contents() |> Enum.map(&part/1),
      provider: put(%{}, "metadata", kept(metadata))
    }

    if error?, do: struct!(ToolError, fields), else: struct!(ToolResult, fields)
  end

  defp contents(text) when is_binary(text), do: [ContentPart.text(text)]
  defp contents(parts) when is_list(parts), do: parts

  defp part(%ContentPart{type: :text, text: text}), do: %Text{text: text || ""}

  defp part(%ContentPart{type: :thinking, text: text, metadata: metadata}),
    do: %Reasoning{text: text || "", provider: put(%{}, "metadata", kept(metadata))}

  defp part(%ContentPart{type: :image_url, url: url}), do: %Uri{modality: "image", uri: url}
  defp part(%ContentPart{type: :video_url, url: url}), do: %Uri{modality: "video", uri: url}

  defp part(%ContentPart{type: :file, file_id: id, media_type: type}) when is_binary(id),
    do: %Wardrik.Conversation.File{file_id: id, mime_type: type}

  defp part(%ContentPart{type: :image, data: data, media_type: type}),
    do: %Blob{modality: "image", data: data || "", mime_type: type}

  defp part(%ContentPart{type: :file, data: data, media_type: type}),
    do: %Blob{modality: "document", data: data || "", mime_type: type}

  # What a model answered with text that reads as a JSON object, which ReqLLM
  # hands back decoded.
  defp part(%{type: :object, object: object}), do: %Text{text: JSON.encode!(object)}

  # What the parts other than reasoning carry besides what Wardrik reads, by
  # their place among the message's parts.
  defp placed(content) do
    content
    |> contents()
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%ContentPart{type: type} = part, at} when type != :thinking ->
        part_kept = %{} |> put("metadata", kept(part.metadata)) |> put("filename", part.filename)
        if part_kept == %{}, do: [], else: [{at, part_kept}]

      _other ->
        []
    end)
    |> Map.new()
  end

  defp call(%ReqLLM.ToolCall{} = call) do
    fields = %{
      id: call.id,
      name: ReqLLM.ToolCall.name(call),
      arguments: arguments(call)
    }

    if ReqLLM.ToolCall.builtin?(call),
      do: struct!(ServerToolCall, fields),
      else: struct!(ToolCall, fields)
  end

  # Arguments the model wrote as something other than a JSON object are kept
  # as written, so validating them refuses the call rather than running it
  # with none.
  defp arguments(call) do
    case ReqLLM.ToolCall.args_map(call) do
      %{} = arguments -> arguments
      _unreadable -> ReqLLM.ToolCall.args_json(call)
    end
  end

  defp calls_metadata(calls) do
    for call <- calls, metadata = ReqLLM.ToolCall.metadata(call), metadata != %{}, into: %{} do
      {call.id, kept(metadata)}
    end
  end

  @doc "What ReqLLM answered a call with, as an answer."
  @spec answer(ReqLLM.Response.t()) :: Answer.t()
  def answer(%ReqLLM.Response{} = response) do
    %Answer{
      message: assistant(response.message),
      usage: usage(ReqLLM.Response.usage(response)),
      finish_reason: finish_reason(response.finish_reason),
      model: response.model,
      id: response.id,
      object: response.object
    }
  end

  defp assistant(nil), do: %Assistant{parts: []}
  defp assistant(%ReqLLM.Message{} = message), do: from_req_llm(message)

  defp usage(nil), do: nil

  defp usage(usage) when is_map(usage) do
    %Usage{
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cached_tokens: usage[:cached_tokens],
      reasoning_tokens: usage[:reasoning_tokens],
      total_cost: usage[:total_cost]
    }
  end

  defp finish_reason(nil), do: nil
  defp finish_reason(reason) when reason in @finish_reasons, do: reason

  defp finish_reason(reason),
    do: Enum.find(@finish_reasons, :unknown, &(Atom.to_string(&1) == to_string(reason)))

  @doc "A tool call as it streams, as one."
  @spec streamed(ReqLLM.StreamChunk.t()) :: ToolCall.t()
  def streamed(%ReqLLM.StreamChunk{type: :tool_call} = chunk),
    do: %ToolCall{id: chunk.metadata[:id], name: chunk.name, arguments: chunk.arguments || %{}}

  @doc """
  Why ReqLLM says a call failed, as an error: with the status the provider
  answered with, where the error carries one or wraps one that does, as a
  stream that broke wraps its request's, and the seconds a `Retry-After`
  header asks for. A date there is not read.
  """
  @spec error(term()) :: Error.t()
  def error(reason) do
    answered = answered(reason)

    %Error{
      status: answered.status,
      retry_after: retry_after(Map.get(answered, :headers) || []),
      message: said(reason)
    }
  end

  defp answered(%{status: status} = error) when is_integer(status), do: error
  defp answered(%{reason: %{status: status} = response}) when is_integer(status), do: response
  defp answered(%{cause: cause}), do: answered(cause)
  defp answered(_reason), do: %{status: nil}

  defp retry_after(headers) do
    Enum.find_value(headers, fn {name, value} ->
      with "retry-after" <- String.downcase(name),
           {seconds, ""} when seconds >= 0 <- value |> List.wrap() |> hd() |> Integer.parse(),
           do: seconds,
           else: (_other -> nil)
    end)
  end

  # What a failure says to a person: the message of the error beneath, where
  # one wraps another.
  defp said(%{cause: %{__exception__: true} = cause}), do: said(cause)
  defp said(%{__exception__: true} = error), do: Exception.message(error)
  defp said(reason), do: inspect(reason)

  # -- provider data --------------------------------------------------------------

  defp put(map, _key, nil), do: map
  defp put(map, _key, empty) when empty == %{}, do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp kept(value) when is_boolean(value) or is_nil(value), do: value
  defp kept(value) when is_atom(value), do: {:atom, Atom.to_string(value)}
  defp kept(value) when is_tuple(value), do: {:tuple, value |> Tuple.to_list() |> kept()}
  defp kept(value) when is_list(value), do: Enum.map(value, &kept/1)

  defp kept(%module{} = value),
    do: {:struct, Atom.to_string(module), value |> Map.from_struct() |> kept()}

  defp kept(value) when is_map(value), do: Map.new(value, fn {k, v} -> {kept(k), kept(v)} end)
  defp kept(value), do: value

  defp restored({:atom, name}), do: String.to_existing_atom(name)
  defp restored({:tuple, elements}), do: elements |> restored() |> List.to_tuple()

  defp restored({:struct, module, fields}),
    do: struct!(String.to_existing_atom(module), restored(fields))

  defp restored(value) when is_list(value), do: Enum.map(value, &restored/1)

  defp restored(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {restored(k), restored(v)} end)

  defp restored(value), do: value
end
