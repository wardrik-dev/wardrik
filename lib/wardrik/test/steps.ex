defmodule Wardrik.Test.Steps do
  @moduledoc """
  Module-shaped `Wardrik.Workflow.Step` implementations.

  Most tests write a step as a function; these exist to exercise the other two
  forms, a bare module and a module with options.
  """

  defmodule Echo do
    @moduledoc "Hands its input back, tagged with whatever options it was given."

    @behaviour Wardrik.Workflow.Step

    @impl true
    def run(input, _scope, []), do: {:ok, input}
    def run(input, _scope, opts), do: {:ok, {input, opts}}
  end

  defmodule Named do
    @moduledoc "Reports the name of the span it was run under."

    @behaviour Wardrik.Workflow.Step

    @impl true
    def run(_input, scope, _opts), do: {:ok, scope.source.trace.name}
  end

  defmodule Boom do
    @moduledoc "Fails the way a step is meant to fail."

    @behaviour Wardrik.Workflow.Step

    @impl true
    def run(_input, _scope, _opts), do: {:error, :boom}
  end

  defmodule Nonsense do
    @moduledoc "Returns something that is not a result at all."

    @behaviour Wardrik.Workflow.Step

    @dialyzer {:nowarn_function, run: 3}
    @impl true
    def run(_input, _scope, _opts), do: :whatever
  end
end
