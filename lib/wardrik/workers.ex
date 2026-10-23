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
  stopped waiting on. A call's `meta` holds the `agent` it's for, the `principal` it acts for, and
  an `idempotencyKey` that stays the same when the call is repeated.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Authorizer
  alias Wardrik.Instance
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias WardrikCore.Context

  @group "workers"
  @prefix "workers__"
  @name ~r/^[A-Za-z0-9_-]{1,55}$/
  @timeout 60_000

  @type call() :: {pid(), reference()}

  @doc """
  Offers the tools a worker lists, in MCP's `tools/list` shape, from the calling process, in place
  of what it offered before, until it exits. Tools whose names a model can't take are left out.
  """
  @spec offer(Scope.t(), [map()]) :: :ok | {:error, term()}
  def offer(%Scope{wardrik: instance} = scope, listed) do
    group = group(instance)
    meta = %{scope: %{scope | wardrik: Instance.name(instance)}, tools: named(listed)}
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
    |> Enum.map(fn {name, offers} -> tool(wardrik.name, name, offers) end)
  end

  defp named(listed), do: Enum.filter(listed, &named?/1)

  defp named?(%{"name" => name}) when is_binary(name), do: Regex.match?(@name, name)
  defp named?(_listed), do: false

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

  defp tool(instance, name, [first | _rest] = offers) do
    WardrikCore.Tool.new!(
      name: @prefix <> name,
      description: description(first.tool) <> "\n\nFrom a tool worker.",
      schema: first.tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
      annotations: annotations(offers),
      run: fn arguments, context -> call(instance, name, arguments, context) end
    )
  end

  defp description(tool), do: tool["description"] || tool["title"] || tool["name"]

  defp annotations(offers) do
    read_only = every?(offers, "readOnlyHint")

    [
      read_only: read_only,
      idempotent: read_only or every?(offers, "idempotentHint"),
      destructive: not read_only and not every?(offers, "destructiveHint", false),
      timeout: @timeout + 5_000
    ]
  end

  defp every?(offers, hint, holds \\ true),
    do: Enum.all?(offers, fn offer -> get_in(offer.tool, ["annotations", hint]) == holds end)

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
    |> Map.merge(principal(Context.acting_for(context)))
  end

  defp agent(id) do
    case String.split(id, "/") do
      [org, "@" <> user, name] -> %{"key" => id, "org" => org, "user" => user, "name" => name}
      [org, name] -> %{"key" => id, "org" => org, "name" => name}
    end
  end

  defp principal(nil), do: %{}
  defp principal(%{id: id}), do: %{"principal" => id}

  defp answered(%{"result" => %{"isError" => true} = result}, context),
    do: {:error, text(result), measured(context, result)}

  defp answered(%{"result" => %{"structuredContent" => structured} = result}, context)
       when is_map(structured),
       do: {:ok, structured, measured(context, result)}

  defp answered(%{"result" => %{} = result}, context),
    do: {:ok, text(result), measured(context, result)}

  defp answered(%{"error" => %{"message" => message}}, _context), do: {:error, message}

  defp answered(_response, _context),
    do: {:error, "The worker answered with neither a result nor an error."}

  defp measured(context, %{"_meta" => %{"costUsd" => usd}}) when is_number(usd) and usd >= 0,
    do: Context.measure(context, :usd, usd)

  defp measured(context, _result), do: context

  defp text(result), do: result |> Map.get("content", []) |> Enum.map_join("\n", &part/1)

  defp part(%{"type" => "text", "text" => text}), do: text
  defp part(%{"type" => "resource", "resource" => %{"text" => text}}), do: text
  defp part(%{"type" => type}), do: "[A part of type #{type} isn't shown here.]"
end
