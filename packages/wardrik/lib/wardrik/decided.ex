defmodule Wardrik.Decided do
  @moduledoc """
  The decisions taken on the calls an agent waits on, as approving,
  denying or deciding answers them, at once.

      maria = %MyApp.Accounts.User{org: "acme", id: 42, email: "maria@acme.example"}

      {:waiting, %Wardrik.Waiting{calls: [%{id: id}]}} = MyApp.Agents.ask(maria, "release", "Ship it")
      {:ok, %Wardrik.Decided{} = decided} = MyApp.Agents.approve(maria, "release", id)
      {:ok, %Wardrik.Reply{text: text}} = MyApp.Agents.await(maria, decided)

  `decisions` are the calls decided, by id: `:approve`, `{:approve, note}`
  or `{:deny, reason}`. Notice the run carries on without you: `await`
  reads how it ends. `run` is the id of the run the decisions carry on, and
  `cursor` is where the agent's log stood as they were taken.
  """

  @enforce_keys [:agent, :run, :decisions, :cursor]
  defstruct @enforce_keys

  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentAddress.t(),
          run: String.t(),
          decisions: %{String.t() => decision()},
          cursor: String.t()
        }
end
