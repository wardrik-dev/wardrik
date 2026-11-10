defmodule WardrikWeb.Test.Resolver do
  @moduledoc false
  @behaviour WardrikWeb.Resolver

  @impl true
  def scope(%WardrikWeb.Resolver.Request{session: %{"user" => user}}, server),
    do: {:ok, Wardrik.Scope.new(server, wardrik: :test, principal: user)}

  def scope(_request, _server), do: {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
end

defmodule WardrikWeb.Test.Extension do
  @moduledoc false
  use WardrikWeb.Extension

  @impl WardrikWeb.Extension
  def pages,
    do: [%WardrikWeb.Page{path: "extra", label: "Extra", live: WardrikWeb.Test.ExtraLive}]

  @impl WardrikWeb.Extension
  def panels(:agents), do: [WardrikWeb.Test.Panel]
  def panels(_slot), do: []
end

defmodule WardrikWeb.Test.ExtraLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p>Extra page for {@scope.principal.id}</p>"
end

defmodule WardrikWeb.Test.Panel do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns), do: ~H"<p>Panel sees {length(@agents)} agents</p>"
end

defmodule WardrikWeb.Test.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import WardrikWeb.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/" do
    pipe_through :browser

    wardrik_dashboard("/ops",
      resolver: {WardrikWeb.Test.Resolver, WardrikWeb.Test.Server},
      extensions: [WardrikWeb.Test.Extension],
      sign_in: "/sign-in"
    )
  end
end

defmodule WardrikWeb.Test.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :wardrik_web

  @session [store: :cookie, key: "_test", signing_salt: "test-salt"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Session, @session
  plug WardrikWeb.Test.Router
end
