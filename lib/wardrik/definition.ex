defmodule Wardrik.Definition do
  @moduledoc """
  What an agent is and what it may do.

      definition =
        Wardrik.Definition.new!(
          model: "anthropic:claude-haiku-4-5",
          instructions: "You watch the incident queue.",
          tools: ["linear/*"],
          policy: [ask: ["linear/*"]]
        )

      Wardrik.Agent.define(scope, "agt_1", definition)
      #=> {:ok, %Wardrik.Agent{id: "agt_1", status: :idle, ...}}

    * Its fields follow the protocol's `agent_definition` schema.
    * `:policy`, `:workspace`, `:context`, `:retries`, `:model_options`, `:compaction` and
      `:notify` stay as JSON.
    * Each of `:triggers` is a `Wardrik.Trigger`.
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
      digest: "digest",
      max_iterations: {"max_iterations", :infinity},
      retries: "retries",
      model_options: "model_options",
      compaction: "compaction",
      triggers: {"triggers", [Wardrik.Trigger]},
      notify: "notify",
      channels: "channels"
    ]

  alias Wardrik.Type

  @schema JSV.build!(WardrikProtocol.schema("agent_definition"))

  @doc "Builds a definition from a keyword list or map. Raises `ArgumentError` if it's invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    json = Type.json(fields)

    case JSV.validate(json, @schema) do
      {:ok, _valid} -> from_json(json)
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc """
  Names each unnamed trigger by position, `trigger-1` and so on, in a JSON definition.
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
