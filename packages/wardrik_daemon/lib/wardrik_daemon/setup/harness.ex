defmodule WardrikDaemon.Setup.Harness do
  @moduledoc """
  What every coding agent's setup step shares: its entry under `config.yaml`'s `harnesses`, and
  `policies/coding.yaml`, where reading runs, each change asks a person, and deleting is refused.
  """

  alias WardrikDaemon.Setup
  alias WardrikDaemon.Setup.Machine

  @doc "Returns whether `config.yaml` has no harness `name`."
  @spec missing?(Machine.t(), String.t()) :: boolean()
  def missing?(%Machine{} = machine, name),
    do: not match?(%{"harnesses" => %{^name => _harness}}, Machine.config(machine))

  @doc "Returns the changes that add the harness `name`, its options the YAML `text`."
  @spec added(String.t(), String.t()) :: [Setup.change()]
  def added(name, text) do
    [
      {:entry, "config.yaml", "harnesses", name,
       "# A tool of the same name, as tools: [#{name}]. It works in a checkout, as\n" <>
         "# checkouts: {app: ~/src/app}, on a branch of its own.\n" <> text},
      {:write, "policies/coding.yaml", policy()}
    ]
  end

  defp policy do
    """
    # For workers that code: reading runs, each change asks a person, and deleting is refused.
    deny: ["*/delete"]
    default: {read_only: allow, else: ask}
    """
  end
end
