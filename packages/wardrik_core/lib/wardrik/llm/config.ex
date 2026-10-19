defmodule Wardrik.LLM.Config do
  @moduledoc """
  What a caller supplies to an agent: which model to run, and what it can call.

  Declarative and inert. Nothing here is assigned by the running system, so a
  config is the piece you can build once and reuse, hand to another agent, or
  read out of a file.

      config = Wardrik.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
      Wardrik.Fleet.spawn(Wardrik.AgentID.new!("assistant", org: "acme"), config: config)

  `:system` is who the agent is. It is prepended to every turn rather than
  stored in the conversation, so changing it changes the agent and replaying a
  context never duplicates it.

      Wardrik.LLM.Config.new(system: "You answer briefly and admit what you do not know.")

  `:tools` is given as `t:Wardrik.Tool.spec/0` values and held as given. The
  tools they name are built where a turn needs them, through `tools/1`. One
  spec may name many tools: see `c:Wardrik.Tool.tools/1`.
  `new/1` builds each one once to check that it can be.

      Wardrik.LLM.Config.new(tools: [MyApp.Tools.Ping])

  `:except_tools` names tools to leave out of those the specs name, so a spec
  that offers more than is wanted keeps what it declares about the rest.

  `:tool_timeouts` caps how long one call to a named tool may take, overriding
  what the tool itself declares in its annotations (`Wardrik.Tool.Annotations`).

      Wardrik.LLM.Config.new(tools: [...], tool_timeouts: %{"deep_research" => :timer.minutes(20)})

  `:tool_prices` is what one call to a tool costs, in US dollars, where the
  tool itself says nothing of what it cost: a call it answered, whether it
  succeeded or failed, carries that price as its cost (see
  `t:Wardrik.Call.cost/0`), and a budget counts it. A tool is named as the
  agent knows it, `github__create_issue`, or as a server's tool,
  `github/create_issue`, with `*` for any run of characters: `github/*`. A
  name given whole wins over a pattern, and a longer pattern over a shorter.

      Wardrik.LLM.Config.new(tools: [...], tool_prices: %{"web_search" => 0.005, "github/*" => 0.0})

  `:generation` is passed to the host's `Wardrik.LLM.Client` as it stands, so
  anything the provider takes can be set here — how long an answer may run,
  and how much of it the model may spend on reasoning, as
  `Wardrik.LLM.ReqLLM` names them.

      Wardrik.LLM.Config.new(generation: [max_tokens: 8_000])
      Wardrik.LLM.Config.new(generation: [reasoning_token_budget: 2_000])
      Wardrik.LLM.Config.new(generation: [provider_options: [thinking: %{type: "disabled"}]])

  Which of those a model honours is the provider's business; `:tools` and
  `:system` are set from their own fields and cannot be overridden here.

  `:history` is what the agent keeps of its history before each turn, a
  `Wardrik.History`: by default `Wardrik.Compaction`, which summarises the
  older history so the rest still fits what the model can read. `nil` keeps
  every message.

      Wardrik.LLM.Config.new(history: {Wardrik.Compaction, Wardrik.Compaction.new(at: 0.5)})

  `:max_iterations` bounds how many rounds of tool calls a turn may make,
  thirty by default. A turn that reaches it is asked to answer with what it
  has, so it still ends with an answer. It is a backstop against an unattended
  agent spending without limit, not a budget — a turn that needs more rounds
  should be given them, and a person watching one can stop it. Set `:infinity`
  where something else is doing the stopping.

  The runtime wiring a turn also needs, such as who its events are published
  to, lives on `Wardrik.Run`.

  ## Travelling

  `dump/1` writes a config down with its module-named tools, and `load/1` reads
  it back on whatever node holds it, where they build their tools again. A
  `Wardrik.Tool` given inline is not named by anything that could build it
  there, so it cannot travel; a module this node cannot build cannot either.
  Both are dropped, and `load/1` warns with their names.
  """

  require Logger

  alias Wardrik.Tool
  alias Wardrik.Tool.Name

  defstruct model_spec: {:zai_coding_plan, model: "glm-5.3-flash"},
            system: nil,
            tools: [],
            except_tools: [],
            tool_timeouts: %{},
            tool_prices: %{},
            generation: [],
            max_iterations: 30,
            history: {Wardrik.Compaction, %Wardrik.Compaction{}}

  @type t :: %__MODULE__{
          model_spec: String.t() | {atom(), keyword()},
          system: String.t() | nil,
          tools: [Tool.spec()],
          except_tools: [String.t()],
          tool_timeouts: %{String.t() => timeout()},
          tool_prices: %{String.t() => number()},
          generation: keyword(),
          max_iterations: pos_integer() | :infinity,
          history: Wardrik.History.t()
        }

  @typedoc "A config written down: its fields, with the names of the tools that could not travel."
  @type dumped() :: %{
          model_spec: String.t() | {atom(), keyword()},
          system: String.t() | nil,
          tools: [module() | {module(), term()}],
          dropped_tools: [String.t()],
          except_tools: [String.t()],
          tool_timeouts: %{String.t() => timeout()},
          tool_prices: %{String.t() => number()},
          generation: keyword(),
          max_iterations: pos_integer() | :infinity,
          history: Wardrik.History.t()
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

  @doc "The tools this config names, built on this node, apart from those it leaves out."
  @spec tools(t()) :: [Tool.t()]
  def tools(%__MODULE__{} = config),
    do: config.tools |> Tool.resolve!() |> Enum.reject(&(&1.name in config.except_tools))

  @typedoc """
  The tools a config names, by name: each as it is built, `nil` for one the
  config leaves out, with the spec that builds it. Where two specs build a
  tool of one name, the first named wins.
  """
  @type tool_index() :: %{String.t() => {Tool.t() | nil, Tool.spec()}}

  @doc """
  Every tool this config names, built once on this node, by name, for what
  looks tools up by name.
  """
  @spec tool_index(t()) :: tool_index()
  def tool_index(%__MODULE__{} = config) do
    for spec <- config.tools, tool <- Tool.resolve!([spec]), reduce: %{} do
      index -> Map.put_new(index, tool.name, {offered(config, tool), spec})
    end
  end

  defp offered(config, tool), do: if(tool.name in config.except_tools, do: nil, else: tool)

  @doc """
  How long one call to the named tool may take: what `:tool_timeouts` says,
  else what the tool's annotations say, else `nil`. `index` is
  `tool_index/1`'s, where the caller has it.
  """
  @spec tool_timeout(t(), String.t(), tool_index() | nil) :: timeout() | nil
  def tool_timeout(%__MODULE__{} = config, name, index \\ nil) do
    Map.get_lazy(config.tool_timeouts, name, fn -> annotated(config, index, name, :timeout) end)
  end

  @doc """
  What one call to the tool the agent knows as `name` costs, in US dollars,
  as `:tool_prices` says, or `nil` where it says nothing.
  """
  @spec tool_price(t(), String.t()) :: number() | nil
  def tool_price(%__MODULE__{tool_prices: prices}, name) do
    case Map.fetch(prices, name) do
      {:ok, usd} ->
        usd

      :error ->
        prices
        |> Enum.filter(fn {pattern, _usd} -> Name.match?(Name.glob(pattern), name) end)
        |> Enum.max_by(fn {pattern, _usd} -> String.length(pattern) end, fn -> {nil, nil} end)
        |> elem(1)
    end
  end

  @doc """
  What a call to the named tool does when whether it had its effect is not
  known, as its annotations say: `:rerun`, or `:ask`. See
  `Wardrik.Tool.Annotations`. `index` is `tool_index/1`'s, where the caller
  has it.
  """
  @spec tool_in_doubt(t(), String.t(), tool_index() | nil) :: :ask | :rerun
  def tool_in_doubt(%__MODULE__{} = config, name, index \\ nil),
    do: annotated(config, index, name, :in_doubt) || :ask

  defp annotated(config, index, name, field) do
    case Map.get(index || tool_index(config), name) do
      nil -> nil
      {_tool, spec} -> Map.fetch!(Tool.annotations(spec, name), field)
    end
  end

  @doc "Writes a config down as data. Tools given inline are kept only by name."
  @spec dump(t()) :: dumped()
  def dump(%__MODULE__{} = config) do
    {travelling, inline} = Enum.split_with(config.tools, &Tool.travels?/1)

    config
    |> Map.from_struct()
    |> Map.merge(%{tools: travelling, dropped_tools: Enum.map(inline, & &1.name)})
  end

  @doc """
  Reads a config back from `dump/1`, keeping the tools this node can build.

  Tools that could not travel, and modules this node does not have, are named
  in a warning and never stop the config being read.
  """
  @spec load(dumped()) :: t()
  def load(%{tools: specs, dropped_tools: dropped} = dumped) do
    {here, missing} = Enum.split_with(specs, &Tool.available?/1)
    warn_dropped(dropped ++ Enum.map(missing, &inspect/1))

    struct!(__MODULE__, dumped |> Map.delete(:dropped_tools) |> Map.put(:tools, here))
  end

  defp warn_dropped([]), do: :ok

  defp warn_dropped(names) do
    Logger.warning("Tools left behind by a config that travelled: #{Enum.join(names, ", ")}")
  end
end
