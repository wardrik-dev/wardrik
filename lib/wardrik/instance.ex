defmodule Wardrik.Instance do
  @moduledoc false

  @doc "Returns the Wardrik `instance` names, as it started, raising where it hasn't."
  @spec fetch!(atom() | Wardrik.t()) :: Wardrik.t()
  def fetch!(%Wardrik{} = wardrik), do: wardrik

  def fetch!(instance) when is_atom(instance) do
    {:ok, wardrik} = Registry.meta(registry(instance), :wardrik)
    wardrik
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(instance)} isn't started. Add it to your supervision tree, ahead of what uses it.",
              __STACKTRACE__
  end

  @doc "Returns the name a Wardrik is reached by."
  @spec name(atom() | Wardrik.t()) :: atom()
  def name(%Wardrik{name: name}), do: name
  def name(instance) when is_atom(instance), do: instance

  @doc "Returns the registry that holds the Wardrik `instance`, and the processes it names."
  @spec registry(atom()) :: atom()
  def registry(instance), do: Module.concat(instance, Registry)
end
