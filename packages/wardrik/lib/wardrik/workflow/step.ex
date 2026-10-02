defmodule Wardrik.Workflow.Step do
  @moduledoc """
  A unit of work: given an input and a scope, produce a result.

  Everything in the workflow layer is a step. A function is a step, a module is
  a step, a fan-out is a step, and a workflow is a step exposed to an agent as
  a tool. There is no step kind and nothing switches on one, so adding a new
  sort of work means writing a module rather than editing a runtime.

      defmodule MyApp.Steps.Summarise do
        @behaviour Wardrik.Workflow.Step

        @impl true
        def run(text, scope, opts) do
          Wardrik.Subagent.run(scope, opts[:config], "Summarise this: \#{text}")
        end
      end

  ## Writing one

  Three forms, all accepted anywhere a step is:

  | Form | Use it for |
  | --- | --- |
  | `fn input, scope -> ... end` | local control flow inside a `run/3` |
  | `MyStep` | a reusable step |
  | `{MyStep, config}` | a reusable step that needs parameterising |

  A function is fine here even though a tool callback should be an MFA. The
  rule about MFAs is for callbacks stored in a config that may cross a node
  boundary; a step function is built and consumed inside one invocation.

  ## Composing them

  `Wardrik.Workflow.fan_out/4` runs a step over many inputs at once and
  `Wardrik.Workflow.sequence/3` runs many steps in order. Both take steps and both
  can be wrapped in one, so composition is closed and a workflow that calls
  another workflow is just a step calling a step.
  """

  alias Wardrik.Scope

  @typedoc "What a step reports."
  @type result() :: {:ok, term()} | {:error, term()}

  @typedoc "A step: a function, a module, or a module with options."
  @type t() :: (term(), Scope.t() -> result()) | module() | {module(), term()}

  @doc """
  Does the work.

  `opts` is whatever the step was named with, or `[]` when it was named as a
  bare module.
  """
  @callback run(input :: term(), scope :: Scope.t(), opts :: term()) :: result()

  @doc """
  Runs `step` on `input` under `scope`.

  Anything other than an ok or error tuple is reported as an error, so callers
  never have to check the shape.
  """
  @spec invoke(t(), term(), Scope.t()) :: result()
  def invoke(step, input, %Scope{} = scope) do
    step |> dispatch(input, scope) |> normalize()
  end

  @doc """
  A short name for a step, used to label its span.

  Modules are named after their last segment; functions have nothing to read,
  so they fall back to their position.
  """
  @spec name(t(), non_neg_integer()) :: String.t()
  def name({module, _opts}, index), do: name(module, index)

  def name(module, _index) when is_atom(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  def name(_step, index), do: "step_#{index}"

  defp dispatch(fun, input, scope) when is_function(fun, 2), do: fun.(input, scope)
  defp dispatch({module, opts}, input, scope), do: module.run(input, scope, opts)
  defp dispatch(module, input, scope) when is_atom(module), do: module.run(input, scope, [])

  defp normalize({:ok, _value} = result), do: result
  defp normalize({:error, _reason} = result), do: result
  defp normalize(other), do: {:error, {:invalid_step_result, other}}
end
