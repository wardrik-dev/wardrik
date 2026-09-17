defmodule TarsLua.Run do
  @moduledoc """
  Runs Lua an agent wrote and hands back the value.

      Tars.LLM.Config.new(tools: [TarsLua.Run])

  The agent reaches it as the `run_lua` tool. It is the way to do work no tool
  covers: arithmetic over numbers it is holding, reshaping a result, a loop, a
  string it would otherwise have to write out by hand.

  The code runs in `TarsLua.Sandbox`, which reaches nothing outside its VM.
  Nothing of the agent's — its tools, its scope, its conversation — is
  reachable from the code either.

  `tool/1` builds the same tool under limits of its own:

      TarsLua.Run.tool(limits: Tars.Sandbox.Limits.new(timeout_ms: :timer.seconds(5)))

  Limits longer than a minute need `:tool_timeouts` on the config to match, or
  `Tars.LLM.ToolRunner` stops the call first.
  """

  @behaviour Tars.Tool

  alias Tars.Sandbox
  alias Tars.Sandbox.Limits
  alias Tars.Tool.Result

  @description """
  Run a snippet of Lua 5.3 and get the value it returns.

  Use it for anything you would otherwise work out by hand: arithmetic and statistics over numbers you are holding, filtering or reshaping a list, parsing and formatting strings, a loop, a small simulation. Prefer it to doing the work in your head whenever being exactly right matters. It is also the way forward when no other tool fits what you need to do.

  Write a chunk that ends in `return`, and nothing comes back otherwise. A table returns as an object, or as an array when its keys are 1..n. `string`, `table`, `math`, `utf8`, `os.time` and `os.date` are available.

  use `os.time` and `os.date` to get the current data/time if needed.

  The VM is sealed: no files, no network, no environment, no `require`, and no access to anything else this agent has. Give it only work that is self-contained, with the data it needs written into the snippet.
  """

  @code_doc "The Lua chunk to run, ending in `return <value>`"

  @returned_nothing "the chunk ran and returned nothing; end it with `return <value>` to get a value back"

  @impl Tars.Tool
  def tool, do: tool([])

  @doc """
  The same tool, built with limits of your own.

  Options are `:limits`, a `t:Tars.Sandbox.Limits.t/0`.
  """
  @spec tool(keyword()) :: ReqLLM.Tool.t()
  def tool(opts) do
    limits = Keyword.get_lazy(opts, :limits, &Limits.new/0)

    ReqLLM.Tool.new!(
      name: "run_lua",
      description: @description,
      parameter_schema: [code: [type: :string, required: true, doc: @code_doc]],
      callback: {__MODULE__, :run, [limits]}
    )
  end

  @doc "Runs one chunk and reports the outcome to the model."
  @spec run(Limits.t(), map() | keyword()) :: Result.t()
  def run(%Limits{} = limits, params) do
    code = params |> Map.new() |> Map.fetch!(:code)

    TarsLua.Sandbox |> Sandbox.run(code, limits) |> answer()
  end

  defp answer({:ok, nil}), do: Result.ok(%{"value" => nil, "note" => @returned_nothing})
  defp answer({:ok, value}), do: Result.ok(%{"value" => value})
  defp answer({:error, message}), do: Result.error(:lua_failed, message)
end
