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

  @impl Wardrik.Authorizer
  def authorize(request, opts) do
    send(Keyword.fetch!(opts, :test), {:authorize, request})
    Keyword.get(opts, :decide, &Wardrik.Test.Allow.authorize(&1, [])).(request)
  end
end

defmodule Wardrik.Test.Deciders do
  @moduledoc """
  Allows everything, but lets a chat member decide only if they're an approver or asked, as a
  host with a channel might.
  """

  @behaviour Wardrik.Authorizer

  @impl Wardrik.Authorizer
  def authorize(%{actor: {:channel, _name}, action: "agent.decide"} = request, _opts) do
    if request.context[:approver] || request.context[:asked_by] == request.principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize(request, opts), do: Wardrik.Test.Allow.authorize(request, opts)
end
