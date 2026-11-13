defmodule Wardrik.AgentTools do
  @moduledoc """
  Tools for working with agents: `agents/*` for other agents, `self/*` for itself.

      tools: ["agents/*", "self/*"]

  | Tool | What it does |
  | --- | --- |
  | `agents_list` | Lists the agents it may read, with each one's description and status, and `"file": true` for one a file declares. |
  | `agent_read`, `self_read` | Reads an agent's status and what it waits on. |
  | `agent_definition_read`, `self_definition_read` | Reads a definition. |
  | `agent_ask` | Sends an agent a message. The answer comes back later as a message. |
  | `agent_define` | Defines or redefines a worker. |
  | `agent_trigger_set`, `agent_trigger_remove`, `self_trigger_set`, `self_trigger_remove` | Changes triggers. |

    * Each acts for the agent's resolved principal, with actor `{:agent, id}`. Your authorizer decides.
    * An agent with no principal can use none of them.
    * Changes are gated: they ask a person unless the policy allows them by name.
    * `agent_ask` carries the asking run's labels.
    * A worker an agent defines is held to its definer's policy.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Delegation
  alias WardrikCore.Context
  alias WardrikCore.Tool

  @agent [
    type: :string,
    required: true,
    doc: "The agent's ID, as agents_list gives it"
  ]
  @trigger [type: :string, required: true, doc: "The trigger's name"]

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id, principal: principal} = context, opts) do
    wardrik = Keyword.fetch!(opts, :wardrik)

    offered(Keyword.fetch!(opts, :reach), %{
      wardrik: wardrik,
      id: id,
      conversation: context.conversation,
      principal: principal,
      policy: nil,
      labels: []
    })
  end

  defp offered(:agents, me) do
    [
      read(
        "agents_list",
        "List the agents you may reach: each one's ID, description and status. \"file\": true marks one an agent file declares, which only a person changes, by editing its file.",
        [],
        fn _args ->
          listed(me)
        end
      ),
      read(
        "agent_read",
        "Read an agent's snapshot: its status, and what it waits on.",
        [agent: @agent],
        &run(me, "agent.read", %{"agent" => &1.agent})
      ),
      read(
        "agent_definition_read",
        "Read an agent's definition.",
        [agent: @agent],
        &run(me, "agent.definition", %{"agent" => &1.agent})
      ),
      change(
        "agent_ask",
        "Send an agent a message. This answers at once; the agent's answer comes back to you later as a message of its own.",
        [agent: @agent, content: [type: :string, required: true, doc: "What you ask it"]],
        &asked(me, &1.agent, &1.content, &2)
      ),
      change(
        "agent_define",
        "Define an agent as a worker, or define it again: its description, instructions, tools and triggers, as a definition takes them. It's held to your policy. An agent a file declares is refused: tell a person what to change in its file.",
        [
          agent: @agent,
          definition: [
            type: :map,
            required: true,
            doc: "The definition, as model, instructions, tools, triggers and the rest"
          ]
        ],
        &defined(me, &1.agent, &1.definition)
      ),
      change(
        "agent_trigger_set",
        "Set one of an agent's triggers: every, or once at a time, with a prompt; or a feed or webhook. It answers with the next run, if any, as next_at.",
        [agent: @agent, trigger: @trigger, fields: trigger_fields()],
        &set(me, &1.agent, &1)
      ),
      change(
        "agent_trigger_remove",
        "Remove one of an agent's triggers.",
        [agent: @agent, trigger: @trigger],
        &run(me, "agent.trigger_remove", %{
          "agent" => &1.agent,
          "trigger" => &1.trigger
        })
      )
    ]
  end

  defp offered(:self, me) do
    self = me.id

    [
      read(
        "self_read",
        "Read your own snapshot: your status, and what you wait on.",
        [],
        fn _args -> run(me, "agent.read", own(me)) end
      ),
      read("self_definition_read", "Read your own definition.", [], fn _args ->
        run(me, "agent.definition", %{"agent" => self})
      end),
      change(
        "self_trigger_set",
        "Set one of your own triggers, to ask yourself something later: once at a time, or every so often. It answers with the next run, if any, as next_at.",
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

  defp own(%{id: id, conversation: nil}), do: %{"agent" => id}

  defp own(%{id: id, conversation: conversation}),
    do: %{"agent" => id, "conversation" => conversation}

  defp trigger_fields,
    do: [
      type: :map,
      required: true,
      doc:
        ~s(The trigger, as {"every": "0 9 * * *", "timezone": "America/Los_Angeles", "prompt": "..."}, or {"at": "2026-11-17T09:00", "timezone": "America/Los_Angeles", "prompt": "..."} to run once. An at trigger is removed after it runs.)
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
      run: fn args, context -> called(run, args, context) end,
      annotations: annotations
    )
  end

  defp called(run, args, _context) when is_function(run, 1), do: run.(args)
  defp called(run, args, context), do: run.(args, context)

  # Each agent's description says what it is, since its ID may not.
  defp listed(me) do
    with {:ok, %{"agents" => agents}} <- run(me, "agents.list", %{}) do
      wardrik = Wardrik.Instance.fetch!(me.wardrik)

      {:ok,
       %{
         "agents" =>
           for(
             agent <- agents,
             not Map.has_key?(agent, "conversation"),
             do: described(wardrik, Map.take(agent, ["id", "status"]))
           )
       }}
    end
  end

  defp described(wardrik, %{"id" => id} = agent) do
    agent =
      if Wardrik.Declarations.declared?(wardrik, id),
        do: Map.put(agent, "file", true),
        else: agent

    case Wardrik.Definitions.fetch(wardrik, id) do
      {:ok, %{"description" => description}} -> Map.put(agent, "description", description)
      _undescribed -> agent
    end
  end

  defp asked(me, agent, message, context) do
    id = "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    me = %{me | labels: Context.labels(context)}

    asker = {me.id, me.conversation}

    with :ok <- Delegation.asked(me.wardrik, asker: asker, agent: agent, message: id),
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
    case Wardrik.Definitions.fetch(wardrik, id) do
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

  defp run(%{principal: nil, id: id}, _operation, _input),
    do: {:error, "#{id} acts for no one, so it can't reach other agents."}

  defp run(me, operation, input) do
    case Wardrik.run(scope(me), operation, input) do
      {:ok, nil} -> {:ok, %{"ok" => true}}
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, error.message}
    end
  end

  defp scope(%{wardrik: wardrik, id: id, principal: principal, policy: policy, labels: labels}) do
    scope = Wardrik.as(wardrik, principal, actor: {:agent, id})
    %{scope | policy: policy, labels: labels}
  end
end
