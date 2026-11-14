defmodule WardrikACP.Tool do
  @moduledoc false

  alias Wardrik.Context
  alias Wardrik.Resume
  alias Wardrik.ToolCall
  alias WardrikACP.Connection
  alias WardrikACP.Harness
  alias WardrikACP.Worktree

  @margin :timer.seconds(5)
  @outside "outside"
  @read_only ~w(read search think fetch)

  @spec new(map(), Harness.t(), [String.t()]) :: Wardrik.Tool.t()
  def new(settings, %Harness{} = harness, checkouts) do
    Wardrik.Tool.new!(
      name: harness.name,
      description: harness.description || description(harness),
      schema: schema(checkouts),
      run: fn args, context -> run(settings, harness, checkouts, args, context) end,
      annotations: [timeout: harness.timeout + @margin]
    )
  end

  defp description(harness) do
    "Sends a coding task to #{harness.name}. It works in a git worktree of the checkout, on a " <>
      "branch of its own, and returns its last message, the branch and its commits."
  end

  defp schema(checkouts) do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "What to do, with everything needed to do it."
        },
        "checkout" => %{
          "type" => "string",
          "enum" => checkouts,
          "description" => "The repository to work in."
        },
        "work" => %{
          "type" => "string",
          "description" =>
            "A short name for this piece of work, such as fix-login. The same name continues the same session and branch."
        }
      },
      "required" => ["task", "checkout", "work"]
    }
  end

  defp run(settings, harness, checkouts, args, context) do
    if args["checkout"] in checkouts,
      do: started(settings, harness, args, context),
      else:
        {:error,
         "No checkout named #{args["checkout"]}. Use one of: #{Enum.join(checkouts, ", ")}."}
  end

  defp started(settings, harness, args, %Context{step: {:tool_call, call}} = context) do
    worktree = worktree(settings, harness, args, context)

    spec = %{
      key: worktree.path,
      harness: harness,
      worktree: worktree,
      file: worktree.path <> ".json"
    }

    with {:ok, pid} <- Connection.open(settings.acp, spec),
         {:ok, attached} <- Connection.attach(pid) do
      reader = %{
        pid: pid,
        monitor: Process.monitor(pid),
        harness: harness,
        worktree: worktree,
        context: context,
        call: call,
        resume: nil,
        approved: nil,
        message: [],
        labels: [],
        refused: [],
        usd: 0
      }

      begin(reader, context.resume, attached, args["task"])
    end
  end

  defp worktree(settings, harness, args, context) do
    checkout = Map.fetch!(settings.checkouts, args["checkout"])

    owner = [
      segment(context.agent_id),
      segment(context.conversation || "_"),
      segment(args["work"])
    ]

    %Worktree{
      checkout: checkout,
      path: Path.join([settings.worktrees, harness.name, segment(args["checkout"]) | owner]),
      branch: Enum.join(["wardrik" | owner], "/")
    }
  end

  defp segment(text) do
    text
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> fallback()
  end

  defp fallback(""), do: "_"
  defp fallback(segment), do: segment

  defp begin(reader, nil, _attached, task), do: prompt(reader, task)

  defp begin(reader, %Resume{reason: :in_doubt}, %{prompting: true, restored: nil}, _task),
    do: read(reader)

  defp begin(reader, %Resume{} = resume, %{prompting: true, restored: nil}, _task),
    do: read(%{reader | resume: resume})

  defp begin(reader, %Resume{reason: :in_doubt}, _attached, task) do
    prompt(
      reader,
      "Wardrik restarted while you worked on this task. Check the worktree, then finish it:\n\n" <>
        task
    )
  end

  defp begin(reader, %Resume{} = resume, %{restored: %{} = request}, task) do
    case decide(%{reader | resume: resume}, request) do
      {:allow, reader} ->
        prompt(
          %{reader | approved: same(request)},
          "A person approved this: #{title(request)}. Try it again, then carry on with the task:\n\n" <>
            task
        )

      {:reject, reason, reader} ->
        prompt(
          reader,
          "A person refused this: #{title(request)}. #{reason} Carry on with the task without it:\n\n" <>
            task
        )

      {:park, reason} ->
        stop(reader, {:park, reason})
    end
  end

  defp begin(reader, %Resume{}, _attached, task),
    do: prompt(reader, "Carry on with the task:\n\n" <> task)

  defp prompt(reader, text) do
    :ok = Connection.prompt(reader.pid, text)
    read(reader)
  end

  defp read(%{pid: pid, monitor: monitor} = reader) do
    receive do
      {WardrikACP, ^pid, event} ->
        event(reader, event)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "#{reader.harness.name} stopped: #{reason(reason)}"}
    end
  end

  defp event(reader, {:update, update}) do
    WardrikCore.Event.emit(reader.context, [:wardrik_acp, :update], %{}, %{
      agent_id: reader.context.agent_id,
      span: reader.context.span,
      harness: reader.harness.name,
      update: update
    })

    read(absorb(reader, update))
  end

  defp event(reader, {:cost, usd}), do: read(%{reader | usd: reader.usd + usd})

  defp event(reader, {:permission, id, request}) do
    case decide(reader, request) do
      {:allow, reader} ->
        Connection.answer(reader.pid, id, :allow)
        read(reader)

      {:reject, reason, reader} ->
        Connection.answer(reader.pid, id, :reject)

        read(%{
          reader
          | refused: reader.refused ++ [%{"title" => title(request), "reason" => reason}]
        })

      {:park, reason} ->
        stop(reader, {:park, reason})
    end
  end

  defp event(reader, {:stopped, "cancelled"}),
    do: stop(reader, {:error, "#{reader.harness.name} was cancelled."})

  defp event(reader, {:stopped, reason}) do
    output =
      reader.worktree
      |> Worktree.report()
      |> Map.merge(%{
        "message" => IO.iodata_to_binary(reader.message),
        "stop_reason" => reason,
        "refused" => reader.refused
      })

    stop(reader, {:ok, answer(output, reader.labels), measured(reader.context, reader.usd)})
  end

  defp event(reader, {:failed, reason}),
    do: stop(reader, {:error, "#{reader.harness.name} failed: #{reason}"})

  defp stop(reader, outcome) do
    Process.demonitor(reader.monitor, [:flush])
    :ok = Connection.detach(reader.pid)
    outcome
  end

  defp measured(context, usd) when usd > 0, do: Context.measure(context, :usd, usd)
  defp measured(context, _usd), do: context

  defp answer(output, []), do: output
  defp answer(output, labels), do: %ReqLLM.ToolResult{output: output, metadata: %{labels: labels}}

  defp absorb(reader, %{
         "sessionUpdate" => "agent_message_chunk",
         "content" => %{"type" => "text", "text" => text}
       }),
       do: %{reader | message: [reader.message | text]}

  defp absorb(reader, %{"sessionUpdate" => kind} = update)
       when kind in ["tool_call", "tool_call_update"] do
    reader = %{reader | message: []}

    if update["kind"] == "fetch",
      do: %{reader | labels: Enum.uniq([@outside | reader.labels])},
      else: reader
  end

  defp absorb(reader, _update), do: reader

  defp decide(%{approved: approved} = reader, request) when approved != nil do
    if same(request) == approved,
      do: {:allow, %{reader | approved: nil}},
      else: decide(%{reader | approved: nil}, request)
  end

  defp decide(reader, request) do
    tool_call = request["toolCall"] || %{}
    kind = tool_call["kind"] || "other"
    name = "#{reader.harness.name}__#{kind}"
    id = "#{reader.call.id}:#{tool_call["toolCallId"]}"
    call = %ToolCall{id: id, name: name, arguments: arguments(tool_call["rawInput"])}

    context = %{
      reader.context
      | resume: answering(reader.resume, reader.call.id, id),
        tools: [step_tool(name, kind, tool_call, reader.worktree) | reader.context.tools],
        messages: reader.context.messages ++ labelled(reader.labels)
    }

    reader = %{reader | resume: nil}

    case Context.run(context, {:tool_call, call}, &{:ok, %{&1 | response: {:ok, :allowed}}}) do
      {:ok, %Context{response: {:ok, _allowed}}} -> {:allow, reader}
      {:ok, %Context{response: {:error, reason}}} -> {:reject, reason(reason), reader}
      {:park, reason, _context} -> {:park, reason}
      {:error, reason} -> {:reject, reason(reason), reader}
    end
  end

  # A person answers the call that parked. The answer is passed on to the request it parked on.
  defp answering(%Resume{input: %{} = input} = resume, call, request),
    do: %{resume | input: %{request => Map.get(input, call)}}

  defp answering(resume, _call, _request), do: resume

  # Paths are relative to the worktree, so a policy matches them as they are in the repository.
  defp step_tool(name, kind, tool_call, worktree) do
    paths =
      for %{"path" => path} <- tool_call["locations"] || [],
          do: Path.relative_to(path, worktree.path)

    read_only = kind in @read_only

    Wardrik.Tool.new!(
      name: name,
      description: tool_call["title"] || name,
      run: fn _args, _context -> {:error, "Run by the coding agent."} end,
      annotations: [
        read_only: read_only,
        destructive: kind == "delete",
        open_world: kind == "fetch",
        gated: not read_only,
        resources: fn _args -> paths end
      ]
    )
  end

  defp labelled([]), do: []

  defp labelled(labels) do
    message = ReqLLM.Context.user("")
    [%{message | metadata: Map.put(message.metadata, :labels, labels)}]
  end

  defp arguments(%{} = input), do: input
  defp arguments(nil), do: %{}
  defp arguments(input), do: %{"input" => input}

  defp same(request) do
    tool_call = request["toolCall"] || %{}
    {tool_call["kind"], tool_call["rawInput"]}
  end

  defp title(request), do: get_in(request, ["toolCall", "title"]) || "a tool call"

  defp reason(reason) when is_binary(reason), do: reason
  defp reason({:shutdown, reason}) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)
end
