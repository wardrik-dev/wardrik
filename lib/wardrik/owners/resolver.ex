defmodule Wardrik.Owners.Resolver do
  @moduledoc """
  Resolves agents as Wardrik does without `:resolver`. See `Wardrik.Resolver`.

  An agent acts for its owner, the part of its ID before its name: `acme/@maria` for
  `acme/@maria/notes`. It reaches every server in Wardrik's `:mcp` and every target in its
  `:notify`, by their names. It gets no policy, defaults or middleware here; your app's own
  resolver gives those.
  """

  alias Wardrik.Definition
  alias Wardrik.Resolved

  @doc "Returns what the request's agent gets."
  @spec resolve(Wardrik.t(), Wardrik.Resolver.Request.t()) :: {:ok, Resolved.t()}
  def resolve(wardrik, %Wardrik.Resolver.Request{agent: id}) do
    {:ok,
     %Resolved{
       principal: Definition.principal(id),
       servers: Map.new(wardrik.mcp, fn {name, _opts} -> {to_string(name), to_string(name)} end),
       notify: Map.new(wardrik.notify.targets, fn {name, _target} -> {name, name} end)
     }}
  end
end
