defmodule WardrikLua do
  @moduledoc """
  Lua 5.3 for agents, as the `run_lua` tool.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik_lua#readme) for complete setup.

      WardrikCore.start_agent(
        agent_id: "agt_triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikLua, limits: [timeout_ms: :timer.seconds(5)]}]
      )

  The VM can't reach files, the network or the environment. See `WardrikLua.Sandbox`.

  ## Options

    * `:limits` - bounds for each run. See `WardrikLua.Sandbox.Limits`.
  """

  @behaviour WardrikCore.Capability

  alias WardrikLua.Sandbox
  alias WardrikLua.Sandbox.Limits

  @description """
  Run a snippet of Lua 5.3 and get the value it returns.

  Use it for anything you'd otherwise work out by hand: arithmetic and statistics over numbers you hold, filtering or reshaping a list, parsing and formatting strings, a loop, a small simulation. Prefer it to doing the work in your head whenever being exactly right matters. It's also the way forward when no other tool fits.

  Write a chunk that ends in `return`, or nothing comes back. A table returns as an object, or as an array when its keys are 1..n. `string`, `table`, `math`, `utf8`, `os.time` and `os.date` are there: use `os.time` and `os.date` for the date and time now.

  Return JSON-compatible data: strings must be valid UTF-8, and functions and cyclic tables can't be returned. Object keys must be strings, numbers or booleans; they become strings and must stay unique.

  The VM is sealed: no files, no network, no environment, no `require`, and nothing else you have. Give it only self-contained work, with the data it needs written into the snippet.
  """

  @returned_nothing "the chunk ran and returned nothing; end it with `return <value>` to get a value back"

  @impl WardrikCore.Capability
  def tools(_context, opts) do
    limits = opts |> Keyword.get(:limits, []) |> Limits.new()

    [
      WardrikCore.Tool.new!(
        name: "run_lua",
        description: @description,
        schema: [
          code: [
            type: :string,
            required: true,
            doc: "The Lua chunk to run, ending in `return <value>`"
          ]
        ],
        run: fn %{code: code}, _context -> code |> Sandbox.run(limits) |> answer() end,
        annotations: [read_only: true, idempotent: true]
      )
    ]
  end

  defp answer({:ok, nil}), do: {:ok, %{value: nil, note: @returned_nothing}}
  defp answer({:ok, value}), do: {:ok, %{value: value}}
  defp answer({:error, message}), do: {:error, message}
end
