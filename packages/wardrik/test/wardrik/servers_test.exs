defmodule Wardrik.ServersTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Servers.Server
  alias Wardrik.Session
  alias Wardrik.Test.Audit

  # Keeps the servers it is given in the test's process, as :added, a map
  # of owner to their servers; the functions run in the test's process.
  defmodule Added do
    @moduledoc false
    defstruct []

    def list(_servers, owner), do: Map.get(Process.get(:added, %{}), owner, [])

    def add(_servers, owner, name: name, fields: fields, by: by) do
      send(self(), {:add, owner, name, fields, by})
      listed = %Server{name: name, url: fields["url"], auth: auth(fields["auth"])}

      cond do
        Enum.any?(list(nil, owner), &(&1.name == name)) ->
          {:error, Error.new(:conflict, "#{owner}#{name} is there already.")}

        listed.auth == "secret" ->
          put(owner, listed)
          {:ok, %{url: "https://auth.example.com/#{name}", code: nil}}

        true ->
          put(owner, listed)
          {:ok, :connected}
      end
    end

    def remove(_servers, owner, name: name, by: _by) do
      case Enum.split_with(list(nil, owner), &(&1.name == name)) do
        {[], _kept} ->
          {:error, Error.new(:not_found, "#{owner} added no #{name}.")}

        {_removed, kept} ->
          Process.put(:added, Map.put(Process.get(:added, %{}), owner, kept))
          :ok
      end
    end

    defp auth(%{"secret" => _secret}), do: "secret"
    defp auth(_none), do: "none"

    defp put(owner, listed),
      do:
        Process.put(:added, Map.update(Process.get(:added, %{}), owner, [listed], &[listed | &1]))
  end

  defimpl Wardrik.Servers, for: Added do
    defdelegate list(a0, a1), to: Added
    defdelegate add(a0, a1, a2), to: Added
    defdelegate remove(a0, a1, a2), to: Added
  end

  @jon Principal.new(:user, "jon", name: "Jon")
  @acme Prefix.parse!("acme/")
  @docs %Server{name: "docs", url: "https://docs.example.com/mcp", auth: "none"}

  defp session(scope, can \\ Grant.actions(), host \\ Host.new(servers: %Added{})) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Session.new(host: host, principal: @jon, grant: grant)
  end

  test "an owner's servers are added, listed and removed, each change recorded as the session's" do
    jon = session("acme/@jon/")
    mine = Prefix.parse!("acme/@jon/")

    assert {:ok, %Server{name: "docs", authorization: nil}} =
             Wardrik.servers_add(jon, mine, @docs)

    assert_received {:add, ^mine, "docs", %{"auth" => %{"none" => %{}}}, @jon}
    assert {:ok, [%Server{name: "docs", auth: "none"}]} = Wardrik.servers_list(jon, mine)

    assert [{"server.added", %{"type" => "user", "id" => "jon"}} | _] =
             Audit.about("servers/acme/@jon/docs")

    assert {:ok, %Server{name: "docs"}} = Wardrik.servers_remove(jon, mine, "docs")
    assert {:ok, []} = Wardrik.servers_list(jon, mine)
    assert {"server.removed", _by} = List.last(Audit.about("servers/acme/@jon/docs"))
  end

  test "a server someone signs in to first answers where, and is added as it is described" do
    crm = %Server{
      name: "crm",
      url: "https://mcp.crm.example/mcp",
      auth: "secret",
      secret: "crm-key",
      only: ["search"]
    }

    assert {:ok, %Server{name: "crm", authorization: %{url: "https://auth.example.com/crm"}}} =
             Wardrik.servers_add(session("acme/"), @acme, crm)

    assert_received {:add, @acme, "crm", fields, @jon}

    assert fields == %{
             "url" => "https://mcp.crm.example/mcp",
             "auth" => %{"secret" => %{"name" => "crm-key"}},
             "only" => ["search"]
           }
  end

  test "the seam's refusal is the function's" do
    {:ok, _added} = Wardrik.servers_add(session("acme/"), @acme, @docs)

    assert {:error, %Error{type: :conflict}} = Wardrik.servers_add(session("acme/"), @acme, @docs)

    assert {:error, %Error{type: :not_found}} =
             Wardrik.servers_remove(session("acme/"), @acme, "nothing")
  end

  test "adding needs define, and a session reaches its own owner alone" do
    assert {:error, %Error{type: :forbidden}} =
             Wardrik.servers_add(session("acme/", [:read]), @acme, @docs)

    assert {:error, %Error{type: :not_found}} =
             Wardrik.servers_add(session("acme/"), Prefix.parse!("globex/"), @docs)
  end

  test "a host that lets nobody add servers answers unsupported" do
    assert {:error, %Error{type: :unsupported}} =
             Wardrik.servers_list(session("acme/", Grant.actions(), Host.new()), @acme)
  end
end
