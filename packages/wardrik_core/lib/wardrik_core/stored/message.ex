defmodule WardrikCore.Stored.Message do
  @moduledoc false

  # Keeps a conversation's messages as JSON that reads back the same, so the model is sent the
  # same request after a restart. Parts are named as the protocol names them: `text`,
  # `reasoning`, `uri`, `blob`, `file`, and `provider_block` for a provider's own. What a
  # provider attaches, such as a thought signature, is kept with `WardrikCore.Stored.Term`.

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias Wardrik.Principal
  alias WardrikCore.Stored.Term

  @roles %{"user" => :user, "assistant" => :assistant, "system" => :system, "tool" => :tool}

  @parts %{
    text: {"text", nil},
    thinking: {"reasoning", nil},
    image_url: {"uri", "image"},
    video_url: {"uri", "video"},
    image: {"blob", "image"},
    file: {"file", nil},
    provider_block: {"provider_block", nil}
  }
  @part_types Map.new(@parts, fn {type, named} -> {named, type} end)

  @spec dump([Message.t()]) :: [Wardrik.Format.json()]
  def dump(messages) when is_list(messages), do: Enum.map(messages, &message/1)

  @doc "Reads messages back. Throws `{:unreadable, reason}`, as `WardrikCore.Stored.Term` does."
  @spec loaded([Wardrik.Format.json()]) :: [Message.t()]
  def loaded(messages) when is_list(messages), do: Enum.map(messages, &read_message/1)

  @spec principal(Principal.t()) :: Wardrik.Format.json()
  def principal(%Principal{id: id, attributes: attributes}),
    do: %{"id" => id, "attributes" => Term.dump(attributes)}

  @spec read_principal(Wardrik.Format.json()) :: Principal.t()
  def read_principal(%{"id" => id, "attributes" => attributes}),
    do: %Principal{id: id, attributes: Term.loaded(attributes)}

  @spec part(ContentPart.t()) :: Wardrik.Format.json()
  def part(%ContentPart{} = part) do
    {type, modality} = Map.fetch!(@parts, part.type)

    %{"type" => type}
    |> put("modality", modality)
    |> put("content", part.text)
    |> put("uri", part.url)
    |> put("data", part.data && Term.dump(part.data))
    |> put("file_id", part.file_id)
    |> put("mime_type", part.media_type)
    |> put("filename", part.filename)
    |> put_map("metadata", part.metadata)
  end

  @spec read_part(Wardrik.Format.json()) :: ContentPart.t()
  def read_part(%{"type" => type} = part) do
    metadata = Map.get(part, "metadata", %{})

    %ContentPart{
      type: part_type(type, part["modality"]),
      text: part["content"],
      url: part["uri"],
      data: part["data"] && Term.loaded(part["data"]),
      file_id: part["file_id"],
      media_type: part["mime_type"],
      filename: part["filename"],
      metadata: Term.loaded(metadata)
    }
  end

  defp message(%Message{} = message) do
    %{"role" => Atom.to_string(message.role), "parts" => Enum.map(message.content, &part/1)}
    |> put("name", message.name)
    |> put("tool_call_id", message.tool_call_id)
    |> put("tool_calls", message.tool_calls && Enum.map(message.tool_calls, &tool_call/1))
    |> put(
      "reasoning",
      message.reasoning_details && Enum.map(message.reasoning_details, &reasoning/1)
    )
    |> put_metadata(message.metadata)
  end

  defp read_message(%{"role" => role, "parts" => parts} = message) do
    %Message{
      role: Map.fetch!(@roles, role),
      content: Enum.map(parts, &read_part/1),
      name: message["name"],
      tool_call_id: message["tool_call_id"],
      tool_calls: message["tool_calls"] && Enum.map(message["tool_calls"], &read_tool_call/1),
      reasoning_details:
        message["reasoning"] && Enum.map(message["reasoning"], &read_reasoning/1),
      metadata: read_metadata(Map.get(message, "metadata", %{}))
    }
  end

  defp part_type(type, modality) do
    case Map.fetch(@part_types, {type, modality}) do
      {:ok, type} -> type
      :error -> throw({:unreadable, "it holds a #{type} part this release doesn't read"})
    end
  end

  defp tool_call(%ReqLLM.ToolCall{id: id, type: type, function: function}),
    do: %{"id" => id, "type" => type, "function" => Term.dump(function)}

  defp read_tool_call(%{"id" => id, "type" => type, "function" => function}),
    do: %ReqLLM.ToolCall{id: id, type: type, function: Term.loaded(function)}

  defp reasoning(%ReasoningDetails{} = details) do
    %{
      "text" => details.text,
      "signature" => details.signature,
      "encrypted" => details.encrypted?,
      "provider" => details.provider && Atom.to_string(details.provider),
      "format" => details.format,
      "index" => details.index,
      "provider_data" => Term.dump(details.provider_data)
    }
  end

  defp reasoning(details), do: %{"value" => Term.dump(details)}

  defp read_reasoning(%{"value" => details}), do: Term.loaded(details)

  defp read_reasoning(details) do
    %ReasoningDetails{
      text: details["text"],
      signature: details["signature"],
      encrypted?: details["encrypted"],
      provider: details["provider"] && Term.atom!(details["provider"]),
      format: details["format"],
      index: details["index"],
      provider_data: Term.loaded(details["provider_data"])
    }
  end

  # A message's own keys are kept by name; what a provider or your app adds goes in "other".
  defp put_metadata(json, metadata) when metadata == %{}, do: json

  defp put_metadata(json, metadata) do
    {known, other} = Map.split(metadata, [:id, :sent_at, :principal, :labels])

    kept =
      %{}
      |> put("id", known[:id])
      |> put("sent_at", known[:sent_at] && DateTime.to_iso8601(known[:sent_at]))
      |> put("principal", known[:principal] && principal(known[:principal]))
      |> put("labels", known[:labels])
      |> put_map("other", other)

    Map.put(json, "metadata", kept)
  end

  defp read_metadata(metadata) do
    known =
      [
        id: metadata["id"],
        sent_at: metadata["sent_at"] && read_time(metadata["sent_at"]),
        principal: metadata["principal"] && read_principal(metadata["principal"]),
        labels: metadata["labels"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    metadata
    |> Map.get("other", %{})
    |> Term.loaded()
    |> Map.merge(known)
  end

  defp read_time(iso) do
    {:ok, time, _offset} = DateTime.from_iso8601(iso)
    time
  end

  defp put(json, _key, nil), do: json
  defp put(json, key, value), do: Map.put(json, key, value)

  defp put_map(json, _key, map) when map == %{}, do: json
  defp put_map(json, key, map), do: Map.put(json, key, Term.dump(map))
end
