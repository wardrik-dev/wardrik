defmodule Wardrik.Definition do
  @moduledoc """
  What an agent is and what it may do: an agent file's frontmatter, as a struct.

      definition =
        Wardrik.Definition.new!(
          model: "anthropic:claude-haiku-4-5",
          instructions: "You watch the incident queue.",
          tools: ["linear/*"],
          policy: [ask: ["linear/*"]]
        )

      Wardrik.Agent.define(scope, "acme/triage", definition)
      #=> {:ok, %Wardrik.Agent{id: "acme/triage", status: :idle, ...}}

  Its fields follow the protocol's `agent_definition` schema. Tools and policies it names must be
  ones Wardrik offers. See `Wardrik.start_link/1`.

  `:policy`, `:workspace`, `:context`, `:retries`, `:compaction` and `:notify` stay as the
  protocol's JSON. Each of `:triggers` is a `Wardrik.Trigger`.
  """

  use Wardrik.Type,
    schema: ["agent_definition"],
    fields: [
      display_name: "display_name",
      description: "description",
      instructions: "instructions",
      model: "model",
      tools: "tools",
      workspace: "workspace",
      context: "context",
      policy: "policy",
      timeout: "timeout",
      idle_timeout: {"idle_timeout", :infinity},
      max_iterations: {"max_iterations", :infinity},
      retries: "retries",
      compaction: "compaction",
      triggers: {"triggers", [Wardrik.Trigger]},
      notify: "notify",
      channels: "channels"
    ]

  alias Wardrik.Type

  @schema JSV.build!(WardrikProtocol.schema("agent_definition"))

  @doc "Builds a definition from a keyword list or map. Raises `ArgumentError` if it doesn't match the schema."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    json = Type.json(fields)

    case JSV.validate(json, @schema) do
      {:ok, _valid} -> from_json(json)
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc """
  Names each unnamed trigger by its position: `trigger-1`, `trigger-2`, and so on.

  Takes and returns the definition as the protocol's JSON.
  """
  @spec named(map()) :: map()
  def named(%{"triggers" => triggers} = definition) do
    named =
      triggers
      |> Enum.with_index(1)
      |> Enum.map(fn {trigger, index} -> Map.put_new(trigger, "name", "trigger-#{index}") end)

    %{definition | "triggers" => named}
  end

  def named(definition), do: definition
end
