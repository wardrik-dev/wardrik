defmodule Wardrik.Digest do
  @moduledoc """
  Writes a digest of a conversation to `digests/` in the agent's workspace before it sleeps.

  A definition turns it off with `digest: false`. It needs the `files` tool.

  ## Notes

    * One file per conversation, rewritten each time: `digests/<conversation>.md`, or
      `digests/agent.md` for the agent's own. Front matter gives `conversation`, `updated` and
      `through`, the ID of the last message it covers.
    * The agent's own model writes it, through its middleware, as the step `digest`. Policy and
      budgets apply.
    * Only the messages after `through` are read, with the digest so far. Without a new message
      from a person or trigger, nothing is written.
    * The file keeps the labels of what it summarizes, such as `"outside"`.
    * Recorded as `wardrik.file.written`, by the agent.
  """

  alias Wardrik.Context
  alias Wardrik.Operations.Changes
  alias Wardrik.Workspace.File
  alias Wardrik.Workspace.Files

  @instructions """
  Write a digest of this conversation, for a later conversation of yours to read. Keep who asked \
  for what, what was decided and done, the names, numbers and paths that matter, and what is left \
  open. If a digest so far is given, fold the newer messages into it. Write only the digest, in \
  Markdown, in under 300 words.\
  """

  @doc "Writes the digest of the conversation `key` from its running process `pid`."
  @spec write(Wardrik.t(), {String.t(), String.t() | nil}, pid()) ::
          :ok | :unchanged | {:error, term()}
  def write(wardrik, {agent, conversation}, pid) do
    context = WardrikCore.context(pid)
    path = path(conversation)
    {prior, version} = prior(wardrik, agent, path)

    newer = newer(context.messages, prior[:through])

    if through(newer),
      do: written(wardrik, context, {agent, conversation}, {path, version}, prior, newer),
      else: :unchanged
  end

  @doc "Returns the workspace path of the conversation's digest."
  @spec path(String.t() | nil) :: String.t()
  def path(nil), do: "digests/agent.md"
  def path(conversation), do: "digests/" <> URI.encode_www_form(conversation) <> ".md"

  defp written(wardrik, context, key, {path, version}, prior, newer) do
    messages = so_far(prior) ++ newer
    summarizing = %{context | instructions: @instructions, messages: messages, tools: []}

    with {:ok, summarized} <-
           Context.run(summarizing, {:step, "digest"}, &WardrikCore.generate/1),
         file = file(context, key, newer, messages, summarized),
         {:ok, version} <-
           Files.write(wardrik.store,
             tree: Wardrik.Workspace.Agents.tree(context.agent_id),
             path: path,
             file: file,
             version: version
           ) do
      recorded(wardrik, context, key, path, version)
    end
  end

  defp file(context, {_agent, conversation}, newer, messages, summarized) do
    at = DateTime.utc_now()

    front = """
    ---
    conversation: #{conversation || "agent"}
    updated: #{DateTime.to_iso8601(at)}
    through: #{through(newer)}
    ---

    """

    text = ReqLLM.Response.text(summarized.response)

    %File{
      content: front <> String.trim(text) <> "\n",
      by: context.agent_id,
      at: at,
      labels: Context.labels(messages)
    }
  end

  defp recorded(wardrik, context, key, path, version) do
    scope = Wardrik.as(wardrik, context.principal, actor: {:agent, context.agent_id})

    Changes.record(%{scope | wardrik: wardrik},
      type: "file.written",
      agent: key,
      data: %{"file" => %{"path" => path, "version" => version}}
    )
  end

  defp prior(wardrik, agent, path) do
    case Files.read(wardrik.store, tree: Wardrik.Workspace.Agents.tree(agent), path: path) do
      {:ok, file, version} -> {parsed(file), version}
      :none -> {%{}, nil}
    end
  end

  defp parsed(%File{content: content} = file) do
    case String.split(content, "\n---\n", parts: 2) do
      ["---\n" <> front, body] ->
        %{through: through_line(front), body: String.trim(body), labels: File.labels(file)}

      _unparsed ->
        %{body: String.trim(content), labels: File.labels(file)}
    end
  end

  defp through_line(front) do
    front
    |> String.split("\n")
    |> Enum.find_value(fn
      "through: " <> id -> String.trim(id)
      _line -> nil
    end)
  end

  defp so_far(%{body: body, labels: labels}),
    do: [
      ReqLLM.Context.user("Your digest of this conversation so far:\n\n" <> body, %{
        labels: labels
      })
    ]

  defp so_far(_none), do: []

  # From the first message with an ID after `through`, or all of them if it isn't in the
  # history. The replies to `through` came before the last digest.
  defp newer(messages, nil), do: messages

  defp newer(messages, through) do
    case Enum.split_while(messages, &(id(&1) != through)) do
      {_all, []} -> messages
      {_before, [_through | after_it]} -> Enum.drop_while(after_it, &is_nil(id(&1)))
    end
  end

  defp through(messages) do
    messages
    |> Enum.map(&id/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp id(%{metadata: %{id: id}}), do: id
  defp id(_message), do: nil
end
