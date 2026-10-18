defmodule Wardrik.Definition.None do
  @moduledoc """
  The `Wardrik.Definition` of a host that keeps no definitions: nothing is
  defined, kept, created or read again, so each operation on definitions is
  `:unsupported`, an agent is forgotten with no definition beside it, and
  every agent starts and wakes as it was stored. A `Wardrik.Host` that names
  no `:definitions` has it.

  An implementation that keeps some of them uses it in its `defimpl`, so
  every function it leaves out answers as this one does:

      defimpl Wardrik.Definition, for: MyApp.Definitions do
        use Wardrik.Definition.None

        def put(definitions, id, definition: fields, token: token), do: ...
      end
  """

  defstruct []

  @type t() :: %__MODULE__{}

  defmacro __using__(_opts) do
    quote do
      def put(_definitions, _id, _opts), do: :unsupported
      def get(_definitions, _id), do: :unsupported
      def delete(_definitions, _id), do: {:error, :not_found}
      def put_trigger(_definitions, _id, _name, _opts), do: :unsupported
      def delete_trigger(_definitions, _id, _name), do: :unsupported
      def editable(_definitions, _id), do: :ok
      def current(_definitions, _id), do: :none
      def defined(_definitions, _prefix), do: []
      def create(_definitions, _id), do: :unsupported
      def reload(_definitions, _opts), do: :ok
      def reloading(_definitions), do: []

      defoverridable put: 3,
                     get: 2,
                     delete: 2,
                     put_trigger: 4,
                     delete_trigger: 3,
                     editable: 2,
                     current: 2,
                     defined: 2,
                     create: 2,
                     reload: 2,
                     reloading: 1
    end
  end
end

defimpl Wardrik.Definition, for: Wardrik.Definition.None do
  use Wardrik.Definition.None
end
