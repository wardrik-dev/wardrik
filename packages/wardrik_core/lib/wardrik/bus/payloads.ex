# The payloads core emits, one struct per kind; see `Wardrik.Bus.Event`.

defmodule Wardrik.Bus.TurnStarted do
  @moduledoc "A turn began, answering `messages`, the `Wardrik.Agent.Message`s it takes."
  @enforce_keys ~w(messages)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          messages: [Wardrik.Agent.Message.t()]
        }
end

defmodule Wardrik.Bus.TurnFinished do
  @moduledoc "A turn answered, with the messages it added."
  @enforce_keys ~w(messages)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          messages: [Wardrik.Conversation.message()]
        }
end

defmodule Wardrik.Bus.TurnFailed do
  @moduledoc "A turn failed, and why."
  @enforce_keys ~w(reason)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          reason: term()
        }
end

defmodule Wardrik.Bus.TurnInterrupted do
  @moduledoc "A turn was stopped, with what it had done."
  @enforce_keys ~w(stats)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          stats: Wardrik.Agent.State.stats()
        }
end

defmodule Wardrik.Bus.TurnParked do
  @moduledoc "A turn waits on a person, for each call with the prompt it was held with."
  @enforce_keys ~w(calls)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          calls: [{Wardrik.Tool.call(), String.t()}]
        }
end

defmodule Wardrik.Bus.TurnResumed do
  @moduledoc "A parked turn carries on, with what was decided of each call."
  @enforce_keys ~w(decisions)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decisions: %{String.t() => term()}
        }
end

defmodule Wardrik.Bus.CallDecided do
  @moduledoc "A person answered the parked call `call_id`, with the `Wardrik.Principal` who did, or `nil` where no caller said."
  @enforce_keys ~w(call_id decision by)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          decision: Wardrik.Call.Pipeline.decision(),
          by: Wardrik.Principal.t() | nil
        }
end

defmodule Wardrik.Bus.MessageQueued do
  @moduledoc "A `Wardrik.Agent.Message` the agent will answer, with who sent it where that is known."
  @enforce_keys ~w(message)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          message: Wardrik.Agent.Message.t()
        }
end

defmodule Wardrik.Bus.AgentStarted do
  @moduledoc "The agent was loaded on `node`, as it stood."
  @enforce_keys ~w(node status generation)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          node: node(),
          status: :idle | :running | :parked,
          generation: String.t()
        }
end

defmodule Wardrik.Bus.AgentStopped do
  @moduledoc "The agent stopped on `node`: `:idle` where it went to sleep for having had nothing to do."
  @enforce_keys ~w(node reason)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          node: node(),
          reason: :idle
        }
end

defmodule Wardrik.Bus.ActivityChanged do
  @moduledoc """
  What the agent is doing changed, as `Wardrik.Agent.Activity` says, on the
  span of the event that changed it. Live: folded from the events before it,
  and never kept.
  """
  @enforce_keys ~w(activity)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          activity: Wardrik.Agent.Activity.t()
        }
end

defmodule Wardrik.Bus.ContextCompacted do
  @moduledoc "The agent's history was rewritten before a turn, as `Wardrik.History` reports it."
  @enforce_keys ~w(stats)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          stats: Wardrik.History.stats()
        }
end

defmodule Wardrik.Bus.ContextCleared do
  @moduledoc "The agent's history was emptied, with how many messages it held."
  @enforce_keys ~w(dropped)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          dropped: non_neg_integer()
        }
end

defmodule Wardrik.Bus.TriggerFired do
  @moduledoc """
  A trigger came due, or was delivered a request, with what came of it, as
  `WardrikTrigger` announces it.
  """
  @enforce_keys ~w(name outcome)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: String.t(),
          outcome: :asked | :nothing_new | :busy | :no_agent | :missed | :failed
        }
end

defmodule Wardrik.Bus.SpanStarted do
  @moduledoc "A span opened, on its own span."
  @enforce_keys ~w(name)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: String.t()
        }
end

defmodule Wardrik.Bus.SpanFinished do
  @moduledoc "A span closed, with how it ended."
  @enforce_keys ~w(outcome duration_ms)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          outcome: Wardrik.Run.outcome(),
          duration_ms: non_neg_integer()
        }
end

defmodule Wardrik.Bus.DelegationStarted do
  @moduledoc "A delegation began, on its own span."
  @enforce_keys ~w(prompt)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          prompt: String.t()
        }
end

defmodule Wardrik.Bus.DelegationFinished do
  @moduledoc "A delegation ended, with what it returned."
  @enforce_keys ~w(outcome duration_ms)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          outcome: {:ok, String.t()} | {:error, term()},
          duration_ms: non_neg_integer()
        }
end

defmodule Wardrik.Bus.ModelStarted do
  @moduledoc "A model call began, answering with the assistant message `message_id` names, with who let it go ahead, as `t:Wardrik.Call.decider/0`."
  @enforce_keys ~w(message_id model_spec decided_by)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          message_id: String.t(),
          model_spec: term(),
          decided_by: Wardrik.Call.decider()
        }
end

defmodule Wardrik.Bus.ModelFinished do
  @moduledoc "A model call ended. `answer` is the `Wardrik.LLM.Answer` it answered with, or `nil` for a call that did not answer, and `cost` what it cost, as `t:Wardrik.Call.cost/0`, or `nil` where it cannot be priced."
  @enforce_keys ~w(message_id outcome duration_ms answer cost)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          message_id: String.t(),
          outcome: :ok | {:error, term()},
          duration_ms: non_neg_integer(),
          answer: Wardrik.LLM.Answer.t() | nil,
          cost: Wardrik.Call.cost() | nil
        }
end

defmodule Wardrik.Bus.ModelRetrying do
  @moduledoc "A model call failed and is asked again after `wait_ms`, as the `attempt`th of `attempts` tries after the first. `message_id` names the try that failed, and `reason` is why it failed."
  @enforce_keys ~w(message_id attempt attempts wait_ms reason)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          message_id: String.t(),
          attempt: pos_integer(),
          attempts: non_neg_integer(),
          wait_ms: non_neg_integer(),
          reason: term()
        }
end

defmodule Wardrik.Bus.Result do
  @moduledoc "Answer text, as it streams."
  @enforce_keys ~w(text)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          text: String.t()
        }
end

defmodule Wardrik.Bus.Thinking do
  @moduledoc "Reasoning text, as it streams."
  @enforce_keys ~w(text)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          text: String.t()
        }
end

defmodule Wardrik.Bus.ToolCall do
  @moduledoc "A tool call as the model streams it, with no arguments yet where they are still to come."
  @enforce_keys ~w(call)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call: Wardrik.Conversation.ToolCall.t()
        }
end

defmodule Wardrik.Bus.DeadlineReached do
  @moduledoc "A turn reached its deadline, with how many messages it had."
  @enforce_keys ~w(message_count)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          message_count: non_neg_integer()
        }
end

defmodule Wardrik.Bus.ToolStarted do
  @moduledoc "A tool call began, with who let it go ahead, as `t:Wardrik.Call.decider/0`, again each time it runs."
  @enforce_keys ~w(call_id name arguments idempotency_key decided_by)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          arguments: map() | String.t(),
          idempotency_key: String.t(),
          decided_by: Wardrik.Call.decider()
        }
end

defmodule Wardrik.Bus.ToolFinished do
  @moduledoc "A tool call answered, with what answered it and what it cost where its tool said, as `t:Wardrik.Call.served/0` and `t:Wardrik.Call.cost/0`."
  @enforce_keys ~w(call_id name result served_by cost)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          result: term(),
          served_by: Wardrik.Call.served() | nil,
          cost: Wardrik.Call.cost() | nil
        }
end

defmodule Wardrik.Bus.ToolReplayed do
  @moduledoc "A tool call answered from the ledger without running again."
  @enforce_keys ~w(call_id name result)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          result: term()
        }
end

defmodule Wardrik.Bus.ToolDenied do
  @moduledoc "A tool call was refused, with why and who refused it."
  @enforce_keys ~w(call_id name reason decided_by)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          reason: String.t(),
          decided_by: Wardrik.Call.decider()
        }
end

defmodule Wardrik.Bus.ToolParked do
  @moduledoc "A tool call waits on a person, who is shown `prompt`."
  @enforce_keys ~w(call_id name prompt)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          prompt: String.t()
        }
end

defmodule Wardrik.Bus.ToolProgress do
  @moduledoc "How far a tool call has got, where `total` is `nil` for work with no known end; see `Wardrik.Tool.Context.progress/3`."
  @enforce_keys ~w(call_id name progress total)a
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          progress: number(),
          total: number() | nil
        }
end
