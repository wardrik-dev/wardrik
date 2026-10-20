defmodule Wardrik.Waiting do
  @moduledoc """
  The calls an agent waits on a person for, when you asked it with `wait:`
  and its run stopped to ask.

      maria = %MyApp.Accounts.User{org: "acme", id: 42, email: "maria@acme.example"}

      {:waiting, %Wardrik.Waiting{calls: [%{id: id}]}} =
        MyApp.Agents.ask(maria, "release", "Ship it", wait: :timer.seconds(30))

      {:ok, %Wardrik.Reply{text: text}} =
        MyApp.Agents.approve(maria, "release", id, wait: :timer.seconds(30))

  Each call has its `id`, to approve or deny it by, the `message` a person
  reads, the tool's `name`, where it is a tool's, and the `reason` it
  waits:

    * `:tool_approval` - a policy asks a person first
    * `:model_approval` - the model call itself waits on a person
    * `:authorization` - a person has an account to connect;
      `c:Wardrik.authorization/3` gives the link
    * `:in_doubt` - the call may already have done what it does

  `run` is the run's id, and `cursor` is where the agent's log stood.
  """

  @enforce_keys [:agent, :run, :calls, :cursor]
  defstruct @enforce_keys

  @type call() :: %{
          id: String.t(),
          reason: :tool_approval | :model_approval | :authorization | :in_doubt,
          message: String.t(),
          name: String.t() | nil
        }

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentAddress.t(),
          run: String.t(),
          calls: [call()],
          cursor: String.t()
        }
end
