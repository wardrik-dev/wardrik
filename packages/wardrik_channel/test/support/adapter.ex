defmodule WardrikChannel.Test.Adapter do
  @moduledoc """
  A channel that tells the test process what it was asked to post. It
  refuses a post in `#nowhere`, and, given `:refusals`, an `Agent` holding a
  count, refuses that many posts first. It answers a request with what it
  was sent, and installs in the workspace a request's `workspace` names.
  """

  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Response
  @behaviour WardrikChannel

  @impl WardrikChannel
  def config(%{"test" => test}), do: {:ok, test: test}
  def config(_settings), do: {:error, ["test"], "is required"}

  @impl WardrikChannel
  def child_spec(opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}

  @impl WardrikChannel
  def deliver(outbound, opts) do
    if refused?(opts[:refusals]) do
      send(opts[:test], {:refused, outbound})
      {:error, :busy}
    else
      send(opts[:test], {:delivered, outbound, opts})
      if outbound.room == "#nowhere", do: {:error, :no_room}, else: {:ok, :posted}
    end
  end

  @impl WardrikChannel
  def include?(names, %WardrikChannel.Member{id: id}, _opts), do: id in names

  @impl WardrikChannel
  def request(request, opts) do
    send(opts[:test], {:request, request, opts})
    Response.json(200, %{path: request.path, body: request.body})
  end

  @impl WardrikChannel
  def install_url(owner, opts),
    do: {:ok, "https://chat.example/install?owner=#{owner}&return_to=#{opts[:return_to]}"}

  @impl WardrikChannel
  def install(owner, request, opts) do
    context = Keyword.fetch!(opts, :context)

    installation = %Installation{
      channel: context.channel,
      workspace: request.query["workspace"],
      owner: owner,
      token: "token-" <> request.query["workspace"]
    }

    case Installations.put(context.installations, installation) do
      :ok -> Response.redirect("https://host.example/installed")
      {:error, message} -> Response.text(409, message)
    end
  end

  defp refused?(nil), do: false

  defp refused?(refusals),
    do: Agent.get_and_update(refusals, fn left -> {left > 0, max(left - 1, 0)} end)
end
