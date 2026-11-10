defmodule WardrikWeb.Resolver do
  @moduledoc """
  Gives the scope a person's dashboard runs in, from their session or what the dashboard's
  `:on_mount` hooks assigned. Every LiveView of the
  dashboard asks it when it mounts, so a session that stops resolving stops working on the next
  reconnect.

      defmodule MyAppWeb.WardrikResolver do
        @behaviour WardrikWeb.Resolver

        @impl true
        def scope(%WardrikWeb.Resolver.Request{session: %{"user_id" => id}}, _opts),
          do: {:ok, Wardrik.as(MyApp.AgentRuntime, id)}

        def scope(_request, _opts),
          do: {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
      end

  Wardrik's authorizer then decides what the scope may do. See `Wardrik.Authorizer`.
  """

  defmodule Request do
    @moduledoc """
    What a resolver reads.

      * `:session` - the Plug session, with string keys.
      * `:endpoint` - the Phoenix endpoint serving the dashboard.
      * `:assigns` - the LiveView's assigns, as the dashboard's `:on_mount` hooks left them,
        such as `:current_user`.
    """

    @enforce_keys [:session, :endpoint, :assigns]
    defstruct [:session, :endpoint, :assigns]

    @type t() :: %__MODULE__{session: map(), endpoint: module(), assigns: map()}
  end

  @doc "Returns the scope the session's person acts in, or why there's none."
  @callback scope(Request.t(), opts :: term()) ::
              {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
end
