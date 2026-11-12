defmodule Wardrik.Triggers.Test.Target do
  @moduledoc "A target that tells the test what it was asked, and answers as the test says."
  @behaviour Wardrik.Triggers.Target

  alias Wardrik.Triggers.Target.Ask
  alias Wardrik.Triggers.Target.Fired
  alias Wardrik.Triggers.Target.Secret

  @impl true
  def ask(%Ask{} = ask, %{test: test, answer: answer}) do
    opts = [trigger: ask.trigger, overlap: ask.overlap, labels: ask.labels]
    send(test, {:asked, ask.agent, ask.prompt, opts})
    answer
  end

  @impl true
  def fired(%Fired{agent: agent, trigger: trigger, status: status}, %{test: test}) do
    send(test, {:fired, agent, trigger, status})
    :ok
  end

  @impl true
  def resolve_secret(%Secret{name: "HOOK_SECRET"}, _opts), do: {:ok, "s3cret"}

  def resolve_secret(%Secret{name: "STANDARD_SECRET"}, _opts),
    do: {:ok, "whsec_" <> Base.encode64("key")}

  def resolve_secret(%Secret{}, _opts), do: :error
end
