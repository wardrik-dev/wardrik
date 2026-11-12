defmodule WardrikCore.SeamsTest do
  use ExUnit.Case, async: true

  # Middleware runs as a pipeline, as Plug does: `call(context, next, opts)`.
  @pipelines [{WardrikCore.Middleware, :call, 3}]

  test "every behaviour's callbacks take one request, then their options" do
    {:ok, modules} = :application.get_key(:wardrik_core, :modules)

    wide =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :behaviour_info, 1),
          {name, arity} <- module.behaviour_info(:callbacks),
          arity > 2,
          {module, name, arity} not in @pipelines,
          do: {module, name, arity}

    assert wide == []
  end
end
