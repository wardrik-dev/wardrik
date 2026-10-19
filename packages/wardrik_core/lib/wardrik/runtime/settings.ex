defprotocol Wardrik.Runtime.Settings do
  @moduledoc """
  An agent's settings, its config: what a `Wardrik.Runtime` read from its
  definition, which every turn it runs is under. `Wardrik.LLM.Config` is one.

  `key/1` names the runtime of the host's that makes its turns, and
  `model/1` the model its status shows. `dump/1` writes the settings down
  with the agent, and `load/1` reads them back on whichever node holds it
  next.
  """

  @doc "The key of the `Wardrik.Runtime` these settings are run by."
  @spec key(t()) :: String.t()
  def key(settings)

  @doc "The model an agent with these settings runs, as its status shows it."
  @spec model(t()) :: term()
  def model(settings)

  @doc "The settings as they are written down with the agent."
  @spec dump(t()) :: t()
  def dump(settings)

  @doc "Reads back settings `dump/1` wrote, on the node that holds the agent now."
  @spec load(t()) :: t()
  def load(settings)
end
