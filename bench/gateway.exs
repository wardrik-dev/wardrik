# How many model-call tries one gateway takes, with many agents calling at once.
#
#   mix run bench/gateway.exs

{:ok, _started} = Application.ensure_all_started(:req_llm)
model = "anthropic:claude-haiku-4-5-20251001"

{:ok, _gateway} =
  WardrikGateway.start_link(
    name: :bench,
    fallbacks: %{model => ["openai:gpt-4o-mini"]},
    limits: %{"anthropic" => [requests_per_minute: 100_000_000]}
  )

# A try is what the middleware asks of the gateway around one model call.
try = fn ->
  GenServer.call(:bench, {:plan, model})
  GenServer.call(:bench, {:admit, [model], 0})
  GenServer.cast(:bench, {:report, model, {:ok, 100}})
end

for callers <- [100, 1_000, 5_000] do
  each = div(200_000, callers)

  {microseconds, :ok} =
    :timer.tc(fn ->
      1..callers
      |> Task.async_stream(fn _caller -> for _try <- 1..each, do: try.() end,
        max_concurrency: callers,
        timeout: :infinity
      )
      |> Stream.run()
    end)

  tries = callers * each

  IO.puts(
    "#{callers} callers: #{round(tries / (microseconds / 1_000_000))} tries a second, " <>
      "#{Float.round(microseconds / tries, 1)} µs a try"
  )
end
