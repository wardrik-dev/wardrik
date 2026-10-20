defmodule WardrikMCP.InstanceTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.Host
  alias Wardrik.Resource
  alias WardrikOAuth.Callback.Page

  defmodule Agents do
    @moduledoc false
    use Wardrik, otp_app: :wardrik_mcp

    @impl Wardrik
    def principal(%{org: org, id: id}), do: %{org: org, id: id}
  end

  def reachable(_url), do: :ok

  setup %{owner: user} do
    start_supervised!(WardrikOAuth.Supervisor)
    stub_server(register: true)

    on_exit(fn ->
      Application.delete_env(:wardrik_mcp, Agents)
      :persistent_term.erase({Wardrik.Instance, Agents})
    end)

    %{owner: Resource.parse!("acme#{user}")}
  end

  # The instance's host as it builds it from `plugins`, signing in against
  # the stub authorization server.
  defp started(plugins) do
    Application.put_env(:wardrik_mcp, Agents,
      store: :memory,
      vault: [keys: [WardrikVault.generate_key()]],
      plugins: plugins
    )

    host = Wardrik.Instance.build(Agents, Agents.config())
    Wardrik.Instance.put(Agents, host)
    host
  end

  defp signing_in,
    do:
      {WardrikOAuth,
       [
         redirect: [url: "https://myapp.example.com/agents/oauth"],
         client: [name: "My app", document_url: "https://myapp.example.com/oauth/client"],
         providers: [],
         poll_floor: 0
       ] ++ requests()}

  defp mcp, do: {WardrikMCP, stderr: :discard}

  # Someone adds a server they sign in to, follows its link, and comes back
  # to the instance's callback page with a code.
  defp signs_in(host, owner) do
    servers = %{Host.servers(host) | check: &__MODULE__.reachable/1}
    fields = %{"url" => resource(), "auth" => %{"oauth" => %{}}}

    assert {:ok, %{url: url}} =
             Wardrik.Servers.add(servers, owner, name: "crm", fields: fields, by: nil)

    {["agents", "oauth", "callback"], {Page, page}} = hd(Host.routes(host))
    conn = Plug.Test.conn(:get, "/agents/oauth/callback/crm?code=c&state=#{state_of(url)}")

    assert Page.call(conn, Page.init(page)).status == 200
    assert {:ok, :grant, _token} = WardrikVault.lookup(Host.credentials(host), "crm", owner)
  end

  test "an added server's sign-in completes with WardrikMCP listed before WardrikOAuth",
       %{owner: owner} do
    signs_in(started([mcp(), signing_in()]), owner)
  end

  test "an added server's sign-in completes with WardrikOAuth listed before WardrikMCP",
       %{owner: owner} do
    signs_in(started([signing_in(), mcp()]), owner)
  end

  test "people add servers only where the instance has a vault" do
    Application.put_env(:wardrik_mcp, Agents, store: :memory, plugins: [mcp()])
    host = Wardrik.Instance.build(Agents, Agents.config())

    assert Host.servers(host) == %Wardrik.Servers.None{}
    assert %WardrikMCP.Servers.Instance{instance: Agents} = Host.servers(started([mcp()]))
  end
end
