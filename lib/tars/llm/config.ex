defmodule Tars.LLM.Config do
  @moduledoc """
  What a caller supplies to an agent: which model to run, and what it can call.

  Declarative and inert. Nothing here is assigned by the running system, so a
  config is the piece you can build once and reuse, hand to another agent, or
  read out of a file.

      config = Tars.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
      Tars.Agent.Supervisor.start(:assistant, config: config)

  `:system` is who the agent is. It is prepended to every turn rather than
  stored in the conversation, so changing it changes the agent and replaying a
  context never duplicates it.

      Tars.LLM.Config.new(system: "You answer briefly and admit what you do not know.")

  `:tools` is given as `t:Tars.Tool.spec/0` values. `new/1` keeps them in
  `:tool_specs` and puts the tools they build in `:tools`, so a config carries
  callable tools from the moment it exists and nothing downstream has to
  resolve anything. `:tools` is derived: set it through `new/1` or
  `add_tool/2`, never by hand.

      Tars.LLM.Config.new(tools: [MyApp.Tools.Ping])

  `:tool_timeouts` caps how long one call to a named tool may take, overriding
  what the tool itself declares through `c:Tars.Tool.timeout/0`.

      Tars.LLM.Config.new(tools: [...], tool_timeouts: %{"deep_research" => :timer.minutes(20)})

  `:generation` is passed to `ReqLLM.stream_text/3` as it stands, so anything
  the provider takes can be set here — how long an answer may run, and how much
  of it the model may spend on reasoning.

      Tars.LLM.Config.new(generation: [max_tokens: 8_000])
      Tars.LLM.Config.new(generation: [reasoning_token_budget: 2_000])
      Tars.LLM.Config.new(generation: [provider_options: [thinking: %{type: "disabled"}]])

  Which of those a model honours is the provider's business; `:tools` and
  `:system` are set from their own fields and cannot be overridden here.

  `:max_iterations` bounds how many rounds of tool calls a turn may make,
  thirty by default. A turn that reaches it is asked to answer with what it
  has, so it still ends with an answer. It is a backstop against an unattended
  agent spending without limit, not a budget — a turn that needs more rounds
  should be given them, and a person watching one can stop it. Set `:infinity`
  where something else is doing the stopping.

  The runtime wiring a turn also needs, such as who its events are published
  to, lives on `Tars.Scope`. Tool callbacks are the one part of a config that
  does not travel: prefer `{module, function}` over an anonymous function for
  any agent that may be started on another node.

  ## Travelling

  `dump/1` writes down the specs a config was built from, and `load/1` resolves
  them again on whatever node reads it. A tool given inline holds a callback
  rather than a name, so it cannot be rebuilt: those are dropped, and `load/1`
  warns with their names.
  """

  require Logger

  alias Tars.Tool

  defstruct model_spec: {:zai_coding_plan, model: "glm-5-turbo"},
            system: nil,
            tools: [],
            tool_specs: [],
            tool_timeouts: %{},
            generation: [],
            max_iterations: 30

  @type t :: %__MODULE__{
          model_spec: {atom(), keyword()},
          system: String.t() | nil,
          tools: list(ReqLLM.Tool.t()),
          tool_specs: list(Tool.spec()),
          tool_timeouts: %{String.t() => timeout()},
          generation: keyword(),
          max_iterations: pos_integer() | :infinity
        }

  @typedoc "A config written down: the specs that travel, and the names of what did not."
  @type dumped() :: %{
          model_spec: {atom(), keyword()},
          system: String.t() | nil,
          tools: [module()],
          dropped_tools: [String.t()],
          tool_timeouts: %{String.t() => timeout()},
          generation: keyword(),
          max_iterations: pos_integer() | :infinity
        }

  @doc """
  Builds a config, resolving every tool it names.

  Use this rather than the struct literal: a tool named as a module is only
  built here. Raises when one cannot be, which is a configuration error worth
  hearing about at construction rather than mid-turn.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = struct(__MODULE__, opts)
    specs = config.tools
    tools = Tool.resolve!(specs)

    %{
      config
      | tools: tools,
        tool_specs: specs,
        tool_timeouts: Map.merge(Tool.timeouts(specs, tools), config.tool_timeouts)
    }
  end

  @spec add_tool(t(), Tool.spec()) :: t()
  def add_tool(%__MODULE__{} = config, tool) do
    %{
      config
      | tools: Tool.resolve!([tool]) ++ config.tools,
        tool_specs: [tool | config.tool_specs]
    }
  end

  @doc """
  Writes a config down as data, keeping module-named tools as modules.

  A tool given inline is kept only as its name, under `:dropped_tools`.
  """
  @spec dump(t()) :: dumped()
  def dump(%__MODULE__{} = config) do
    {modules, inline} = Enum.split_with(config.tool_specs, &is_atom/1)

    %{
      model_spec: config.model_spec,
      system: config.system,
      tools: modules,
      dropped_tools: Enum.map(inline, & &1.name),
      tool_timeouts: config.tool_timeouts,
      generation: config.generation,
      max_iterations: config.max_iterations
    }
  end

  @doc """
  Rebuilds a config from `dump/1`, resolving its tool modules on this node.

  Tools that could not travel are named in a warning and never stop the config
  being rebuilt.
  """
  @spec load(dumped()) :: t()
  def load(dumped) when is_map(dumped) do
    warn_dropped(Map.get(dumped, :dropped_tools, []))

    dumped
    |> Map.drop([:dropped_tools])
    |> Keyword.new()
    |> new()
  end

  defp warn_dropped([]), do: :ok

  defp warn_dropped(names) do
    Logger.warning("Tools left behind by a config that travelled: #{Enum.join(names, ", ")}")
  end

  # For testing, to be removed eventually
  def test_tools do
    {:ok, tool_1} =
      ReqLLM.Tool.new(
        name: "echo",
        description: "echo",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn i -> {:ok, i} end
      )

    {:ok, tool_2} =
      ReqLLM.Tool.new(
        name: "fail",
        description: "fail",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn _i -> {:error, "failed"} end
      )

    {:ok, tool_3} =
      ReqLLM.Tool.new(
        name: "crash",
        description: "crash",
        parameter_schema: [
          value: [type: :any, required: true]
        ],
        callback: fn _i -> raise "crashed" end
      )

    [tool_1, tool_2, tool_3]
  end
end
