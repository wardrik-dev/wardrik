defmodule WardrikDaemon.CreateAgent do
  @moduledoc """
  Makes an agent by name: mints its ID, records it, and defines it.

  `POST /v1/owners/{owner}/agents` uses it, and so does the `agent_create` tool:

      tools: [self/*, agents/*, agent_create]

    * The worker gets the calling agent's owner, org and policy.
    * It waits on a person, as `agent_define` does, unless the policy allows it.
    * It's checked as `create` on `agent` for `agent:NAME`.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Error
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Agents

  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @input @openapi_path
         |> File.read!()
         |> JSON.decode!()
         |> get_in(["components", "schemas", "agent_input"])
         |> JSV.build!()

  @typedoc "What it needs: the Wardrik's `:wardrik` name, and the daemon's own `:store`."
  @type daemon() :: %{required(:wardrik) => atom(), required(:store) => WardrikStore.t()}

  @doc """
  Makes the agent `input` describes (`name` plus its definition) for `owner`. The caller checks access.
  """
  @spec create(daemon(), Wardrik.Scope.t(), {String.t(), map()}) ::
          {:ok, AgentRecords.t()} | {:error, Error.t()}
  def create(daemon, scope, {owner, input}) do
    with :ok <- an_owner_of_agents(owner),
         {:ok, %{"name" => name} = input} <- valid(input),
         {:ok, record} <- recorded(daemon, owner, name),
         {:ok, _snapshot} <- defined(daemon, scope, record, Map.delete(input, "name")),
         do: {:ok, record}
  end

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id, principal: principal}, opts) do
    daemon = Map.new(opts)

    [
      WardrikCore.Tool.new!(
        name: "agent_create",
        description:
          "Make a worker, an agent of your org with a name of its own, and define it: its description, instructions, tools and triggers, as a definition takes them. It's held to your policy. Answers its ID.",
        schema: [
          name: [
            type: :string,
            required: true,
            doc: "Its name, unique in your org: lowercase words joined by dashes"
          ],
          definition: [
            type: :map,
            required: true,
            doc:
              "The definition, as model, instructions, tools, triggers and the rest. Its workspace.shared names agents of your org as agent:NAME"
          ]
        ],
        run: fn args, _context -> made(daemon, {id, principal}, args) end,
        annotations: [gated: true]
      )
    ]
  end

  defp made(_daemon, {id, nil}, _args),
    do: {:error, "#{id} acts for no one, so it can't make agents."}

  defp made(daemon, {id, principal}, %{name: name, definition: definition}) do
    scope = %{
      Wardrik.as(daemon.wardrik, principal, actor: {:agent, id})
      | policy: policy(daemon.wardrik, id)
    }

    # A model's arguments are JSON already; this makes any keys strings, as the route's are.
    input = definition |> JSON.encode!() |> JSON.decode!() |> Map.put("name", name)

    with :ok <- authorized(scope, principal.id),
         {:ok, record} <- create(daemon, scope, {principal.id, input}) do
      {:ok, %{"id" => record.id, "name" => record.name, "org" => record.org}}
    else
      {:error, %Error{message: message}} -> {:error, message}
    end
  end

  defp authorized(scope, owner) do
    case Wardrik.Authorizer.authorize(scope, action: "agent.create", resource: {:agents, owner}) do
      :ok -> :ok
      {:error, _denied} -> {:error, Error.new(:forbidden, "You may not make agents.")}
    end
  end

  # A worker is held to its maker's policy, as agent_define holds it.
  defp policy(wardrik, id) do
    case Wardrik.run(Agents.scope(wardrik: wardrik), "agent.definition", %{"agent" => id}) do
      {:ok, %{"definition" => %{"policy" => policy}}} -> policy
      _unbounded -> nil
    end
  end

  defp valid(input) do
    case JSV.validate(input, @input) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  defp an_owner_of_agents("deployment"),
    do: {:error, Error.new(:invalid_request, "An agent is an org's or a person's: give one.")}

  defp an_owner_of_agents(_owner), do: :ok

  defp recorded(%{wardrik: wardrik, store: store}, owner, name) do
    gone? = &Agents.gone?([wardrik: wardrik], &1)

    case AgentRecords.create(store, owner: owner, name: name, replaces: gone?) do
      {:ok, record} ->
        {:ok, record}

      {:error, {:taken, record}} ->
        {:error, Error.new(:conflict, "#{record.org} has an agent called #{name} already.")}
    end
  end

  # An agent that isn't defined has no record, so its name is free.
  defp defined(%{store: store}, scope, record, definition) do
    with {:ok, definition} <- identified(store, record, definition),
         {:ok, snapshot} <-
           Wardrik.run(scope, "agent.define", Map.put(definition, "agent", record.id)) do
      {:ok, snapshot}
    else
      {:error, error} ->
        :ok = AgentRecords.delete(store, record)
        {:error, error}
    end
  end

  defp identified(store, record, definition) do
    case AgentRecords.identified(store, record.org, definition) do
      {:ok, definition} -> {:ok, definition}
      {:error, why} -> {:error, Error.new(:invalid_request, why <> ".")}
    end
  end
end
