defmodule WardrikGateway.StateTest do
  use ExUnit.Case, async: true

  alias WardrikGateway.Settings
  alias WardrikGateway.State

  @haiku "anthropic:claude-haiku-4-5-20251001"
  @mini "openai:gpt-4o-mini"

  defp state(opts) do
    opts
    |> Settings.new!()
    |> State.new()
  end

  defp failed(state, model, times),
    do:
      Enum.reduce(1..times, state, fn _time, state ->
        elem(State.report(state, model, :failed, 0), 1)
      end)

  test "plans a model's fallbacks after it" do
    state = state(fallbacks: %{@haiku => [@mini]})
    assert {[@haiku, @mini], 600_000} = State.plan(state, @haiku)

    state = state([])
    assert {[@mini], 600_000} = State.plan(state, @mini)
  end

  test "opens a model's breaker after its failures, and skips to the next model" do
    state = failed(state(breaker: [failures: 2, open_for: 1_000]), @haiku, 1)
    assert {{:go, @haiku, 0}, _state} = State.admit(state, [@haiku, @mini], 0, 0)

    assert {[{[:wardrik_gateway, :breaker_opened], %{model: @haiku}}], state} =
             State.report(state, @haiku, :failed, 0)

    assert {{:go, @mini, 0}, _state} = State.admit(state, [@haiku, @mini], 0, 0)
    assert {{:wait, 1_000}, _state} = State.admit(state, [@haiku], 0, 0)
  end

  test "forgets failures older than its window" do
    state = state(breaker: [failures: 2, within: 100])
    {[], state} = State.report(state, @haiku, :failed, 0)
    assert {[], _state} = State.report(state, @haiku, :failed, 500)
  end

  test "lets one call try an open model again, and closes or reopens on its answer" do
    state = failed(state(breaker: [failures: 1, open_for: 1_000]), @haiku, 1)

    assert {{:go, @haiku, 0}, probing} = State.admit(state, [@haiku], 0, 1_000)
    assert {{:wait, 1_000}, _state} = State.admit(probing, [@haiku], 0, 1_000)

    assert {[{[:wardrik_gateway, :breaker_closed], %{model: @haiku}}], closed} =
             State.report(probing, @haiku, {:ok, 0}, 1_000)

    assert {{:go, @haiku, 0}, _state} = State.admit(closed, [@haiku], 0, 1_000)

    assert {[{[:wardrik_gateway, :breaker_opened], _model}], reopened} =
             State.report(probing, @haiku, :failed, 1_000)

    assert {{:wait, 1_000}, _state} = State.admit(reopened, [@haiku], 0, 1_000)
  end

  test "lets a minute's requests through, then spaces the rest" do
    state = state(limits: %{"anthropic" => [requests_per_minute: 2]})
    {{:go, @haiku, 0}, state} = State.admit(state, [@haiku], 0, 0)
    {{:go, @haiku, 0}, state} = State.admit(state, [@haiku], 0, 0)

    assert {{:wait, 30_000}, _state} = State.admit(state, [@haiku], 0, 0)
    assert {{:go, @haiku, 30_000}, _state} = State.admit(state, [@haiku], 30_000, 0)
    assert {{:go, @mini, 0}, _state} = State.admit(state, [@haiku, @mini], 0, 0)
  end

  test "holds a provider for the tokens spent past its limit" do
    state = state(limits: %{"anthropic" => [tokens_per_minute: 1_000]})
    {[], state} = State.report(state, @haiku, {:ok, 2_000}, 0)
    assert {{:wait, 60_000}, _state} = State.admit(state, [@haiku], 0, 0)
  end

  test "holds a provider that answered 429 for as long as it asked" do
    state = state([])
    {[], state} = State.report(state, @haiku, {:limited, 5_000}, 0)
    assert {{:wait, 5_000}, _state} = State.admit(state, [@haiku], 0, 0)
    assert {{:go, @haiku, 5_000}, _state} = State.admit(state, [@haiku], 5_000, 0)
  end

  test "ignores a failure a retry won't fix, and a failure while open" do
    state = state(breaker: [failures: 1])
    assert {[], ^state} = State.report(state, @haiku, :hopeless, 0)

    open = failed(state, @haiku, 1)
    assert {[], ^open} = State.report(open, @haiku, :failed, 0)
  end

  test "refuses a model the catalog doesn't know, and a bad limit" do
    for fallbacks <- [%{"nope:nope" => []}, %{@haiku => ["nope:nope"]}, %{@haiku => "x"}, []] do
      assert_raise NimbleOptions.ValidationError, fn -> Settings.new!(fallbacks: fallbacks) end
    end

    assert_raise NimbleOptions.ValidationError, fn -> Settings.new!(limits: []) end

    assert_raise NimbleOptions.ValidationError, fn ->
      Settings.new!(limits: %{"anthropic" => [requests_per_minute: 0]})
    end
  end
end
