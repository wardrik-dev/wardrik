defmodule WardrikWeb.Resolver do
  @moduledoc """
  A resolver decides who can use the dashboard.

  It returns the `Wardrik.Scope` that a signed-in person acts in. It can read the session and the
  assigns set by your `:on_mount` hooks. Return an error to refuse access.

  The dashboard calls the resolver each time a page loads. When you remove someone's access, they
  lose the dashboard the next time their browser reconnects.

      defmodule MyAppWeb.WardrikResolver do
        @behaviour WardrikWeb.Resolver

        @impl true
        def scope(%WardrikWeb.Resolver.Request{session: %{"user_id" => id}}, _opts),
          do: {:ok, Wardrik.as(MyApp.AgentRuntime, id)}

        def scope(_request, _opts),
          do: {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
      end

  Wardrik's authorizer checks each action the person takes. See `Wardrik.Authorizer`.
  """

  defmodule Request do
    @moduledoc """
    The request a resolver receives.

      * `:session` - the Plug session, with string keys.
      * `:endpoint` - the Phoenix endpoint serving the dashboard.
      * `:assigns` - the LiveView's assigns after your `:on_mount` hooks ran. For example,
        `:current_user`.
    """

    @enforce_keys [:session, :endpoint, :assigns]
    defstruct [:session, :endpoint, :assigns]

    @type t() :: %__MODULE__{session: map(), endpoint: module(), assigns: map()}
  end

  @doc "Returns the scope for the signed-in person, or an error that refuses access."
  @callback scope(Request.t(), opts :: term()) ::
              {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
end
