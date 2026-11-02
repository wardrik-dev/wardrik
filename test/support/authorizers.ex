defmodule Wardrik.Test.Allow do
  @moduledoc """
  Allows everything, for tests that only need access to work, unless the scope's context holds
  `:decide`, a function of the request that decides it. See `Wardrik.Test.Wardrik.limited/3`.
  """

  @behaviour Wardrik.Authorizer

  @impl Wardrik.Authorizer
  def authorize(%{context: %{decide: decide}} = request, _opts), do: decide.(request)
  def authorize(_request, _opts), do: :ok
end

defmodule Wardrik.Test.Authorizer do
  @moduledoc """
  Tells the test each request, as `{:authorize, request}`, and decides it with `:decide`, a
  function of the request. Decides as `Wardrik.Test.Allow` unless `:decide` is set.
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Test.Allow

  @impl Wardrik.Authorizer
  def authorize(request, opts) do
    send(Keyword.fetch!(opts, :test), {:authorize, request})
    Keyword.get(opts, :decide, &Allow.authorize(&1, [])).(request)
  end
end

defmodule Wardrik.Test.Deciders do
  @moduledoc """
  Decides as a host with a channel might. A chat member reaches only the agents of the
  installation's owner. Of them, only `acme/@maria`, whose own binding allows it, or whoever
  asked may decide. Allows everything else.
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Test.Allow

  @impl Wardrik.Authorizer
  def authorize(%{actor: {:channel, _name}, resource: {:agent, id}} = request, opts) do
    if owner(id) == request.context.installation.owner,
      do: member(request, opts),
      else: {:error, :not_found}
  end

  def authorize(request, opts), do: Allow.authorize(request, opts)

  defp member(%{action: "agent.decide"} = request, _opts) do
    if request.principal.id == "acme/@maria" or request.context[:asked_by] == request.principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  defp member(request, opts), do: Allow.authorize(request, opts)

  defp owner(id), do: Wardrik.Test.Directory.owner(id)
end
