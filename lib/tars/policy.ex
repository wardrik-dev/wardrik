defmodule Tars.Policy do
  @moduledoc """
  Whether a tool call may run, decided before it does.

  Tars ships no policy. A deployment that needs one names a module here and
  `Tars.LLM.ToolRunner` asks it about every call, so governance is a property
  of the runtime rather than something each tool remembers to check.

      Tars.Fleet.spawn("assistant", config: config, policy: MyApp.Policy)

  A policy sees the call and the scope it would run under, which carries the
  user and organisation the work is for. It sees no credentials and resolves
  none: deciding and
  dispensing are separate jobs, and a policy that could read a secret would be
  a second place secrets leak from.

      defmodule MyApp.Policy do
        @behaviour Tars.Policy

        @impl true
        def authorize(%{name: "delete_" <> _rest}, scope) do
          if scope.user.admin?,
            do: {:ask, "This deletes production data."},
            else: {:deny, "Only an admin may delete."}
        end

        def authorize(_call, _scope), do: :allow
      end

  ## The three answers

    * `:allow` - run it.
    * `{:deny, reason}` - do not run it. The model is told, in the reason's
      words, and gets to do something else. A refusal is an answer, not a
      failure, so the turn carries on.
    * `{:ask, prompt}` - do not run it yet. The call parks, the turn stops with
      nothing appended to the conversation, and the agent waits for
      `Tars.Agent.resume/2`. The prompt is what a person is shown.

  An `{:ask, prompt}` with nobody to answer it leaves the agent parked until it
  is resumed or interrupted, which is the correct outcome: the alternative is
  running the call anyway.

  ## Deciding without a policy

  A run with no policy allows everything, so the default costs nothing and no
  branch anywhere has to handle a missing one.
  """

  @typedoc "What a policy says about one call."
  @type decision() :: :allow | {:deny, String.t()} | {:ask, String.t()}

  @doc """
  Decides whether `call` may run under `scope`.

  Called once per tool call, in the task that would execute it, before the
  tool's callback is invoked. A policy that raises denies the call rather than
  failing the turn.
  """
  @callback authorize(call :: Tars.Tool.call(), scope :: Tars.Scope.t()) :: decision()

  @doc """
  Asks `policy` about `call`, answering `:allow` when there is no policy.

  A policy that raises, throws or exits is treated as a refusal. Governance
  that fails open is not governance, and a broken policy module is a
  deployment error worth seeing in the conversation.
  """
  @spec authorize(module() | nil, Tars.Tool.call(), Tars.Scope.t()) :: decision()
  def authorize(nil, _call, _scope), do: :allow

  def authorize(policy, call, scope) when is_atom(policy) do
    case policy.authorize(call, scope) do
      :allow -> :allow
      {:deny, reason} when is_binary(reason) -> {:deny, reason}
      {:ask, prompt} when is_binary(prompt) -> {:ask, prompt}
      other -> {:deny, "Policy #{inspect(policy)} returned #{inspect(other)}"}
    end
  catch
    kind, reason -> {:deny, "Policy #{inspect(policy)} failed: #{Exception.format(kind, reason)}"}
  end
end
