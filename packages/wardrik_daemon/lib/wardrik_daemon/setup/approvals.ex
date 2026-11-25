defmodule WardrikDaemon.Setup.Approvals do
  @moduledoc """
  How much agents do without asking a person. `wardrik init` asks as it writes a first
  `config.yaml`, and writes the answer as `policies/<answer>.yaml` and `defaults.policy`.

    * `careful` - every call of a gated tool asks: making a worker, sending mail, pushing code.
    * `balanced` - the assistant makes, changes and asks its own workers freely, even after
      reading mail or the web. Gated tools that act outside Wardrik ask. Deleting is refused.
    * `hands-off` - every call runs, even after reading mail or the web, except deleting.

  Each keeps a budget of 2,000,000 tokens a day per agent. Without a terminal, the answer is
  `balanced` unless `--set approvals=NAME` gives another.
  """

  alias WardrikDaemon.Setup.Choice

  @workers ~w(agent_create agent_define agent_ask agent_schedule agent_trigger_set
              agent_trigger_remove self_schedule self_trigger_set self_trigger_remove)

  @doc "Returns the question `wardrik init` asks."
  @spec question() :: Choice.t()
  def question,
    do: %Choice{
      key: "approvals",
      label: "How much should agents do without asking you?",
      default: "balanced",
      options: [
        {"balanced",
         "Balanced: the assistant makes and runs its workers freely; sending, posting and " <>
           "pushing ask you"},
        {"careful", "Careful: every change asks you, such as making a worker or sending mail"},
        {"hands-off",
         "Hands-off: everything runs without asking, even after reading mail or the web, " <>
           "except deleting"}
      ]
    }

  @doc "Returns the policy file the answer `name` names, as its path and text."
  @spec policy_file(String.t()) :: {Path.t(), String.t()}
  def policy_file(name), do: {"policies/#{name}.yaml", policy(name)}

  defp policy("careful") do
    """
    # Careful: every call of a gated tool asks a person, such as making a worker, sending mail or
    # pushing code. Reading, searching and the agent's own files run.
    budget: {tokens: 2000000, per: day}
    """
  end

  defp policy("balanced") do
    """
    # Balanced: the assistant makes, changes and asks its own workers without asking, even after
    # reading mail or the web; each worker is held to this policy too. Gated tools that act
    # outside Wardrik, such as sending mail or pushing code, ask a person. Deleting is refused.
    allow: #{yaml_list(@workers)}
    allow_after:
      outside: #{yaml_list(@workers)}
    deny:
      "*delete*": Deleting is left to a person.
      "*DELETE*": Deleting is left to a person.
    budget: {tokens: 2000000, per: day}
    """
  end

  defp policy("hands-off") do
    """
    # Hands-off: every call runs without asking, even after reading mail or the web, except
    # deleting. The budget caps what agents spend.
    allow: ["*"]
    allow_after:
      outside: ["*"]
    deny:
      "*delete*": Deleting is left to a person.
      "*DELETE*": Deleting is left to a person.
    budget: {tokens: 2000000, per: day}
    """
  end

  defp yaml_list(names), do: "[#{Enum.join(names, ", ")}]"
end
