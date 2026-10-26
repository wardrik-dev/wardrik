defmodule Wardrik.AgentTools do
  @moduledoc """
  The tools that let an agent work with agents: `agents/*`, over the other agents of its org, and
  `self/*`, over itself. Each runs an operation of the catalog through `Wardrik.run/3`, as the agent,
  so its tools reach what any surface's would and nothing more.

  | Tool | Operation |
  | --- | --- |
  | `agents_list` | lists the agents of the org, and what each is doing |
  | `agent_read`, `self_read` | reads a snapshot: its status, what it waits on |
  | `agent_definition_read`, `self_definition_read` | reads a definition |
  | `agent_ask` | sends one a message; its answer comes back later as a message |
  | `agent_define` | defines a worker, or defines one again |
  | `agent_trigger_set`, `agent_trigger_remove`, `self_trigger_set`, `self_trigger_remove` | changes triggers |

  An agent is named within the org, as `reconciler`, or `@jon/reconciler` for one that works for a
  user. Reads run freely. Every change is `gated`: it waits on a person unless the agent's policy
  allows it by name, as `allow: [agent_ask]`. A worker an agent defines is held to the policy of the
  agent that defined it.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.AgentID
  alias Wardrik.Delegation
  alias WardrikCore.Principal
  alias WardrikCore.Tool

  @agent [
    type: :string,
    required: true,
    doc: "The agent, by its name in your org, as reconciler or @jon/reconciler"
  ]
  @trigger [type: :string, required: true, doc: "The trigger's name"]

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id}, opts) do
    wardrik = Keyword.fetch!(opts, :wardrik)
    offered(Keyword.fetch!(opts, :reach), %{wardrik: wardrik, id: id, org: org(id), policy: nil})
  end

  defp offered(:agents, me) do
    [
      read("agents_list", "List the agents of your org, and what each is doing.", [], fn _args ->
        listed(me)
      end),
      read(
        "agent_read",
        "Read an agent's snapshot: its status, and what it waits on.",
        [agent: @agent],
        &run(me, "agent.read", %{"agent" => named(me, &1.agent)})
      ),
      read(
        "agent_definition_read",
        "Read an agent's definition.",
        [agent: @agent],
        &run(me, "agent.definition", %{"agent" => named(me, &1.agent)})
      ),
      change(
        "agent_ask",
        "Send an agent a message. This answers at once; the agent's answer comes back to you later as a message of its own.",
        [agent: @agent, message: [type: :string, required: true, doc: "What you ask it"]],
        &asked(me, named(me, &1.agent), &1.message)
      ),
      change(
        "agent_define",
        "Define an agent of your org as a worker, or define it again: its description, instructions, tools and triggers, as a definition takes them. It's held to your policy.",
        [
          agent: @agent,
          definition: [
            type: :map,
            required: true,
            doc: "The definition, as model, instructions, tools, triggers and the rest"
          ]
        ],
        &defined(me, named(me, &1.agent), &1.definition)
      ),
      change(
        "agent_trigger_set",
        "Set one of an agent's triggers: every, with a prompt, or a feed or webhook.",
        [agent: @agent, trigger: @trigger, fields: trigger_fields()],
        &set(me, named(me, &1.agent), &1)
      ),
      change(
        "agent_trigger_remove",
        "Remove one of an agent's triggers.",
        [agent: @agent, trigger: @trigger],
        &run(me, "agent.trigger_remove", %{
          "agent" => named(me, &1.agent),
          "trigger" => &1.trigger
        })
      )
    ]
  end

  defp offered(:self, me) do
    self = AgentID.agent(me.id)

    [
      read(
        "self_read",
        "Read your own snapshot: your status, and what you wait on.",
        [],
        fn _args -> run(me, "agent.read", %{"agent" => me.id}) end
      ),
      read("self_definition_read", "Read your own definition.", [], fn _args ->
        run(me, "agent.definition", %{"agent" => self})
      end),
      change(
        "self_trigger_set",
        "Set one of your own triggers.",
        [trigger: @trigger, fields: trigger_fields()],
        &set(me, self, &1)
      ),
      change(
        "self_trigger_remove",
        "Remove one of your own triggers.",
        [trigger: @trigger],
        &run(me, "agent.trigger_remove", %{"agent" => self, "trigger" => &1.trigger})
      )
    ]
  end

  defp trigger_fields,
    do: [
      type: :map,
      required: true,
      doc:
        ~s(The trigger, as {"every": "0 9 * * *", "timezone": "America/Los_Angeles", "prompt": "..."})
    ]

  defp read(name, description, schema, run),
    do: tool(name, description, schema, run, read_only: true, idempotent: true)

  defp change(name, description, schema, run),
    do: tool(name, description, schema, run, gated: true)

  defp tool(name, description, schema, run, annotations) do
    Tool.new!(
      name: name,
      description: description,
      schema: schema,
      run: fn args, _context -> run.(args) end,
      annotations: annotations
    )
  end

  defp listed(me) do
    with {:ok, %{"agents" => agents}} <-
           run(me, "agents.list", %{"resources" => [me.org <> "/*"]}) do
      {:ok,
       %{
         "agents" =>
           for(
             agent <- agents,
             not AgentID.conversation?(agent["id"]),
             do: Map.take(agent, ["id", "status"])
           )
       }}
    end
  end

  defp asked(me, agent, message) do
    id = "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- Delegation.asked(me.wardrik, me.id, agent, id),
         do: run(me, "agent.ask", %{"agent" => agent, "content" => message, "id" => id})
  end

  defp defined(me, agent, definition) do
    wardrik = Wardrik.Instance.fetch!(me.wardrik)

    if Wardrik.Declarations.declared?(wardrik, agent),
      do: {:error, "#{agent} is declared by a file, which a person changes."},
      else:
        run(
          %{me | policy: policy(wardrik, me.id)},
          "agent.define",
          definition |> Wardrik.Type.json() |> Map.put("agent", agent)
        )
  end

  defp policy(wardrik, id) do
    case Wardrik.Definitions.fetch(wardrik, AgentID.agent(id)) do
      {:ok, %{"policy" => policy}} -> policy
      _unbounded -> nil
    end
  end

  defp set(me, agent, args),
    do:
      run(
        me,
        "agent.trigger_set",
        args.fields
        |> Wardrik.Type.json()
        |> Map.merge(%{"agent" => agent, "trigger" => args.trigger})
      )

  defp run(me, operation, input) do
    case Wardrik.run(scope(me), operation, input) do
      {:ok, nil} -> {:ok, %{"ok" => true}}
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, error.message}
    end
  end

  defp scope(%{wardrik: wardrik, id: id, org: org, policy: policy}) do
    {:ok, resource} = Wardrik.Resource.agent(id)

    scope =
      Wardrik.as(wardrik, %Principal{id: resource},
        roles: [:reader, :messenger, :definer],
        resources: [org <> "/*"]
      )

    %{scope | policy: policy}
  end

  defp named(me, "@" <> _user = name), do: me.org <> "/" <> name
  defp named(me, name), do: me.org <> "/" <> String.trim_leading(name, me.org <> "/")

  defp org(id), do: id |> String.split("/", parts: 2) |> hd()
end
