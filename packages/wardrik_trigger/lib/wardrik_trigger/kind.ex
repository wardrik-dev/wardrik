defprotocol WardrikTrigger.Kind do
  @moduledoc """
  What a kind of trigger gives `WardrikTrigger` to run it, so `put/2`,
  `sync/2`, `encode/1` and the listings take every kind alike: a trigger on a
  clock, `%WardrikTrigger{}`, and a webhook, `%WardrikTrigger.Webhook{}`.

  A new kind is a struct with a `name`, a `DurableServer` that runs it, and an
  implementation of this. Its server joins its agent's triggers with
  `WardrikTrigger.join/2` as it starts, answers `{:configure, trigger}` with
  `:ok`, and puts in its registry metadata what `WardrikTrigger.Status`
  reports: `agent`, `name`, `schedule`, `next`, `paths`, `last_at` and
  `last_outcome`.
  """

  @doc """
  The key its process runs under for `agent`: unique among the agent's
  triggers of every kind, so a trigger whose name changes kind is another
  process.
  """
  @spec key(t(), Wardrik.AgentID.t()) :: String.t()
  def key(trigger, agent)

  @doc "The server that runs it for `agent`, and the state that server starts from."
  @spec child(t(), Wardrik.AgentID.t()) :: {module(), term()}
  def child(trigger, agent)

  @doc "It written as text, with its name, as `WardrikTrigger.decode/2` reads it back."
  @spec encode(t()) :: %{String.t() => term()}
  def encode(trigger)
end
