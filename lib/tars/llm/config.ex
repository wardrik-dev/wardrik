defmodule Tars.LLM.Config do
  @moduledoc """
  What a caller supplies to an agent: which model to run, and what it can call.

  Declarative and inert. Nothing here is assigned by the running system, so a
  config is the piece you can build once and reuse, hand to another agent, or
  read out of a file.

      config = Tars.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
      Tars.Fleet.spawn("assistant", config: config)

  `:system` is who the agent is. It is prepended to every turn rather than
  stored in the conversation, so changing it changes the agent and replaying a
  context never duplicates it.

      Tars.LLM.Config.new(system: "You answer briefly and admit what you do not know.")

  `:tools` is given as `t:Tars.Tool.spec/0` values and held as given. The
  tools they name are built where a turn needs them, through `tools/1`.
  `new/1` builds each one once to check that it can be.

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
  to, lives on `Tars.Scope`.

  ## Travelling

  `dump/1` writes a config down with its module-named tools, and `load/1` reads
  it back on whatever node holds it. A tool given inline holds a callback
  rather than a name, so it cannot travel; a module this node cannot build
  cannot either. Both are dropped, and `load/1` warns with their names.
  """

  require Logger

  alias Tars.Tool

  defstruct model_spec: {:zai_coding_plan, model: "glm-5-turbo"},
            system: nil,
            tools: [],
            tool_timeouts: %{},
            generation: [],
            max_iterations: 30

  @type t :: %__MODULE__{
          model_spec: {atom(), keyword()},
          system: String.t() | nil,
          tools: [Tool.spec()],
          tool_timeouts: %{String.t() => timeout()},
          generation: keyword(),
          max_iterations: pos_integer() | :infinity
        }

  @typedoc "A config written down: its fields, with the names of the tools that could not travel."
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
  Builds a config, checking every tool it names can be built here.

  Raises when one cannot be, which is a configuration error worth hearing
  about at construction rather than mid-turn.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = struct(__MODULE__, opts)
    Tool.resolve!(config.tools)
    config
  end

  @spec add_tool(t(), Tool.spec()) :: t()
  def add_tool(%__MODULE__{} = config, spec) do
    Tool.resolve!([spec])
    %{config | tools: [spec | config.tools]}
  end

  @doc "The tools this config names, built on this node."
  @spec tools(t()) :: [ReqLLM.Tool.t()]
  def tools(%__MODULE__{} = config), do: Tool.resolve!(config.tools)

  @doc """
  How long one call to the named tool may take: what `:tool_timeouts` says,
  else what the tool declares, else `nil`.
  """
  @spec tool_timeout(t(), String.t()) :: timeout() | nil
  def tool_timeout(%__MODULE__{} = config, name) do
    Map.get_lazy(config.tool_timeouts, name, fn -> declared(config, name) end)
  end

  defp declared(config, name) do
    config.tools
    |> Enum.zip(tools(config))
    |> Enum.find_value(fn {spec, tool} -> tool.name == name and Tool.timeout(spec) end)
  end

  @doc "Writes a config down as data. Tools given inline are kept only by name."
  @spec dump(t()) :: dumped()
  def dump(%__MODULE__{} = config) do
    {modules, inline} = Enum.split_with(config.tools, &is_atom/1)

    config
    |> Map.from_struct()
    |> Map.merge(%{tools: modules, dropped_tools: Enum.map(inline, & &1.name)})
  end

  @doc """
  Reads a config back from `dump/1`, keeping the tools this node can build.

  Tools that could not travel, and modules this node does not have, are named
  in a warning and never stop the config being read.
  """
  @spec load(dumped()) :: t()
  def load(%{tools: modules, dropped_tools: dropped} = dumped) do
    {here, missing} = Enum.split_with(modules, &Tool.available?/1)
    warn_dropped(dropped ++ Enum.map(missing, &inspect/1))

    struct!(__MODULE__, dumped |> Map.delete(:dropped_tools) |> Map.put(:tools, here))
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
