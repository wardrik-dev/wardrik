defmodule WardrikWeb.Assets do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @static Application.app_dir(:wardrik_web, "priv/static")
  @phoenix Application.app_dir(:phoenix, "priv/static/phoenix.min.js")
  @live_view Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.min.js")

  for path <- [@phoenix, @live_view, "#{@static}/wardrik_web.js", "#{@static}/wardrik_web.css"],
      do: @external_resource(path)

  @js Enum.map_join([@phoenix, @live_view, "#{@static}/wardrik_web.js"], "\n", &File.read!/1)
  @css File.read!("#{@static}/wardrik_web.css")

  @assets %{
    "app-#{Base.encode16(:crypto.hash(:md5, @js), case: :lower)}.js" => {"text/javascript", @js},
    "app-#{Base.encode16(:crypto.hash(:md5, @css), case: :lower)}.css" => {"text/css", @css}
  }

  @doc "Returns the asset names, `{js, css}`, the layout links to."
  @spec names() :: {String.t(), String.t()}
  def names do
    {Enum.find(Map.keys(@assets), &String.ends_with?(&1, ".js")),
     Enum.find(Map.keys(@assets), &String.ends_with?(&1, ".css"))}
  end

  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(%Plug.Conn{path_params: %{"asset" => asset}} = conn, :show) do
    case Map.fetch(@assets, asset) do
      # The dashboard is mounted in a :browser pipeline, whose forgery protection refuses
      # JavaScript; this is a static asset, not a response to a forged request.
      {:ok, {type, body}} ->
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> put_resp_content_type(type, nil)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, body)
        |> halt()

      :error ->
        conn |> send_resp(404, "") |> halt()
    end
  end
end
