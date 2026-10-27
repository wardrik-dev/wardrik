defmodule Wardrik.Workers do
  @moduledoc """
  The tools workers offer: programs that connect to Wardrik and run calls in their own process, as
  MCP servers do. A definition names them as `workers/*`, and the model sees each as
  `workers__refund_order`.

  An agent is offered the tools of every worker whose scope may `agent.serve` it, as the `:worker`
  role allows. Workers of one principal that offer the same tool share its calls. Where another's
  offer it too, the agent gets the one whose worker connected first.

  A surface holds each worker's connection in a process of its own. It offers what the worker lists
  with `offer/2`. It's sent each call as `{Wardrik.Workers, :call, call, name, arguments, meta}`,
  and answers it with `answer/2`. It's sent `{Wardrik.Workers, :cancel, call}` for a call Wardrik
  stopped waiting on. A tool is gated unless every worker offering it marks it read-only, and its
  answers are labelled `"outside"` unless Wardrik's `:trusted_workers` says otherwise. A call's
  `meta` holds the `agent` it's for, the `run` it's part of, the `principal` it acts for,
  and an `idempotencyKey` that stays the same when the call is repeated.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.AgentID
  alias Wardrik.Authorizer
  alias Wardrik.Instance
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias WardrikCore.Context

  @group "workers"
  @prefix "workers__"
  @name ~r/^[A-Za-z0-9_-]{1,55}$/
  @timeout 60_000
  @hints ~w(readOnlyHint idempotentHint destructiveHint openWorldHint)

  @type call() :: {pid(), reference()}

  @doc """
  Offers the tools a worker lists, in MCP's `tools/list` shape, from the calling process, in place
  of what it offered before, until it exits. A tool whose name a model can't take, or that doesn't
  read as MCP describes it, is left out.
  """
  @spec offer(Scope.t(), term()) :: :ok | {:error, term()}
  def offer(%Scope{wardrik: instance} = scope, listed) do
    group = group(instance)
    meta = %{scope: %{scope | wardrik: Instance.name(instance)}, tools: readable(listed)}
    Group.join(group, @group, Map.put(meta, :since, since(group)))
  end

  @doc "Answers `call` with the worker's JSON-RPC response to `tools/call`."
  @spec answer(call(), map()) :: :ok
  def answer({caller, ref}, response) do
    send(caller, {ref, response})
    :ok
  end

  @doc false
  @spec group(atom() | Wardrik.t()) :: atom()
  def group(instance), do: Module.concat(Instance.name(instance), Workers)

  @impl WardrikCore.Capability
  def tools(%Context{agent_id: id}, opts) do
    wardrik = opts |> Keyword.fetch!(:wardrik) |> Instance.fetch!()

    wardrik
    |> offered(id)
    |> Enum.group_by(fn offer -> offer.tool["name"] end)
    |> Enum.map(fn {name, offers} -> tool(wardrik, name, offers) end)
  end

  defp readable(listed) when is_list(listed), do: Enum.flat_map(listed, &readable_tool/1)
  defp readable(_listed), do: []

  defp readable_tool(%{"name" => name} = tool) when is_binary(name) do
    with true <- Regex.match?(@name, name),
         {:ok, schema} <- schema(tool["inputSchema"]) do
      [
        %{
          "name" => name,
          "description" => described(tool["description"], tool["title"], name),
          "inputSchema" => schema,
          "annotations" => hints(tool["annotations"])
        }
      ]
    else
      _unreadable -> []
    end
  end

  defp readable_tool(_tool), do: []

  defp schema(nil), do: {:ok, %{"type" => "object", "properties" => %{}}}

  defp schema(%{"type" => "object"} = schema) do
    case JSV.build(schema) do
      {:ok, _root} -> {:ok, schema}
      {:error, _reason} -> :error
    end
  end

  defp schema(_schema), do: :error

  defp described(description, _title, _name) when is_binary(description), do: description
  defp described(_description, title, _name) when is_binary(title), do: title
  defp described(_description, _title, name), do: name

  defp hints(%{} = annotations),
    do: Map.filter(annotations, fn {hint, holds} -> hint in @hints and is_boolean(holds) end)

  defp hints(_annotations), do: %{}

  defp since(group) do
    case List.keyfind(Group.local_members(group, @group), self(), 0) do
      {_worker, %{since: since}} -> since
      nil -> System.system_time()
    end
  end

  defp offered(wardrik, id) do
    {:ok, resource} = Resource.agent(id)

    offers =
      for {worker, %{scope: scope, tools: tools, since: since}} <-
            Group.members(group(wardrik), @group),
          serves?(wardrik, scope, resource),
          tool <- tools,
          do: %{worker: worker, principal: scope.principal.id, since: since, tool: tool}

    Enum.filter(offers, &first_offered?(&1, offers))
  end

  defp serves?(wardrik, scope, resource),
    do: Authorizer.authorize(%{scope | wardrik: wardrik}, "agent.serve", resource) == :ok

  defp first_offered?(offer, offers) do
    first =
      offers
      |> Enum.filter(fn other -> other.tool["name"] == offer.tool["name"] end)
      |> Enum.min_by(fn other -> {other.since, other.principal} end)

    first.principal == offer.principal
  end

  defp tool(wardrik, name, [first | _rest] = offers) do
    WardrikCore.Tool.new!(
      name: @prefix <> name,
      description: first.tool["description"] <> "\n\nFrom a tool worker.",
      schema: first.tool["inputSchema"],
      annotations: annotations(offers, wardrik.trusted_workers),
      run: fn arguments, context -> call(wardrik.name, name, arguments, context) end
    )
  end

  defp annotations(offers, trusted) do
    read_only = every?(offers, "readOnlyHint")

    [
      read_only: read_only,
      idempotent: read_only or every?(offers, "idempotentHint"),
      destructive: not read_only and not every?(offers, "destructiveHint", false),
      gated: not read_only,
      labels: labels(trusted),
      timeout: @timeout + 5_000
    ]
  end

  defp labels(true), do: []
  defp labels(false), do: ["outside"]

  defp every?(offers, hint, holds \\ true),
    do: Enum.all?(offers, fn offer -> offer.tool["annotations"][hint] == holds end)

  defp call(instance, name, arguments, %Context{agent_id: id} = context) do
    offers =
      for %{tool: %{"name" => ^name}} = offer <- offered(Instance.fetch!(instance), id), do: offer

    case offers do
      [] -> {:error, "No worker offers #{name} now, so it didn't run."}
      offers -> ask(Enum.random(offers).worker, name, arguments, context)
    end
  end

  defp ask(worker, name, arguments, context) do
    ref = Process.monitor(worker)
    send(worker, {__MODULE__, :call, {self(), ref}, name, arguments, meta(context)})

    receive do
      {^ref, response} ->
        Process.demonitor(ref, [:flush])
        answered(response, context)

      {:DOWN, ^ref, :process, _worker, :noproc} ->
        {:error, "No worker offers #{name} now, so it didn't run."}

      {:DOWN, ^ref, :process, _worker, _reason} ->
        {:error, "The worker running #{name} went away before it answered. It may have run."}
    after
      @timeout ->
        Process.demonitor(ref, [:flush])
        send(worker, {__MODULE__, :cancel, {self(), ref}})
        {:error, "#{name} didn't answer in time. It may have run."}
    end
  end

  defp meta(%Context{agent_id: id, step: {:tool_call, call}} = context) do
    %{"agent" => agent(id), "idempotencyKey" => call.id}
    |> Map.merge(run(context.span))
    |> Map.merge(principal(Context.acting_for(context)))
  end

  defp run(%WardrikCore.Span{trace: trace}), do: %{"run" => trace}
  defp run(nil), do: %{}

  defp agent(id) do
    {:ok, %AgentID{owner: owner, name: name, conversation: conversation}} = AgentID.parse(id)

    %{"key" => id, "name" => name}
    |> Map.merge(owner(owner))
    |> Map.merge(conversation(conversation))
  end

  defp owner(owner) do
    case String.split(owner, "/@") do
      [org, user] -> %{"org" => org, "user" => user}
      [org] -> %{"org" => org}
    end
  end

  defp conversation(nil), do: %{}
  defp conversation(conversation), do: %{"conversation" => conversation}

  defp principal(nil), do: %{}
  defp principal(%{id: id}), do: %{"principal" => id}

  defp answered(%{"result" => %{"isError" => true} = result}, context),
    do: {:error, text(result), measured(context, result)}

  defp answered(%{"result" => %{"structuredContent" => structured} = result}, context)
       when is_map(structured),
       do: {:ok, structured, measured(context, result)}

  defp answered(%{"result" => %{} = result}, context),
    do: {:ok, text(result), measured(context, result)}

  defp answered(%{"error" => %{"message" => message}}, _context) when is_binary(message),
    do: {:error, message}

  defp answered(_response, _context),
    do: {:error, "The worker answered with neither a result nor an error."}

  defp measured(context, %{"_meta" => %{"costUsd" => usd}}) when is_number(usd) and usd >= 0,
    do: Context.measure(context, :usd, usd)

  defp measured(context, _result), do: context

  defp text(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, "\n", &part/1)

  defp text(_result), do: ""

  defp part(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp part(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text),
    do: text

  defp part(%{"type" => type}) when is_binary(type),
    do: "[A part of type #{type} isn't shown here.]"

  defp part(_part), do: "[A part that doesn't read isn't shown here.]"
end
