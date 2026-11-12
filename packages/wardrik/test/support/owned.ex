defmodule Wardrik.Test.Owned do
  @moduledoc """
  Resolves agents as a simple app might, for tests: each acts for its owner in
  `Wardrik.Test.Directory`, and reaches every server and notify target of the
  Wardrik named in `opts`. Give `opts` as `{name, more}` to add `:channels`, or `:shares`, the
  workspaces each agent may mount by its ID.
  """

  @behaviour Wardrik.Resolver

  @impl Wardrik.Resolver
  def resolve(%Wardrik.Resolver.Request{agent: id}, {name, more}) do
    {shares, more} = Keyword.pop(more, :shares, %{})
    {:ok, resolved} = resolve(%Wardrik.Resolver.Request{agent: id}, name)
    workspaces = Map.get(shares, id, %{})
    {:ok, struct!(resolved, [workspaces: workspaces] ++ more)}
  end

  def resolve(%Wardrik.Resolver.Request{agent: id}, name) do
    {mcp, targets} = started(name)

    {:ok,
     %Wardrik.Resolved{
       principal: principal(id),
       servers: Map.new(mcp, fn {server, _opts} -> {to_string(server), to_string(server)} end),
       notify: Map.new(targets, fn {target, _target} -> {target, target} end)
     }}
  end

  # A Wardrik a test resolves through before it starts reaches nothing.
  defp started(name) do
    wardrik = Wardrik.Instance.fetch!(name)
    {wardrik.mcp, wardrik.notify.targets}
  rescue
    ArgumentError -> {[], %{}}
  end

  defp principal(id), do: %WardrikCore.Principal{id: Wardrik.Test.Directory.owner(id)}
end
