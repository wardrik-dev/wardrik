defmodule Wardrik.ServersTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Catalog
  alias Wardrik.Command
  alias Wardrik.Connections.Owner
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Operations.AddServer
  alias Wardrik.Operations.ReadServers
  alias Wardrik.Operations.RemoveServer
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Servers.Server
  alias Wardrik.Test.Audit

  # Keeps the servers it is given in the test's process, as :added, a map
  # of owner to their servers; operations run in the test's process.
  defmodule Added do
    @moduledoc false
    defstruct []

    def list(_servers, owner), do: Map.get(Process.get(:added, %{}), owner, [])

    def add(_servers, owner, name: name, fields: fields, by: by) do
      send(self(), {:add, owner, name, by})
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

  defp caller(scope, can \\ Grant.actions(), host \\ Host.new(servers: %Added{})) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope), can)
    Caller.new(principal: @jon, grant: grant, host: host)
  end

  defp run(module, caller, whose, input) do
    {:ok, owner} = Owner.owner(caller, whose)
    runner = if module == ReadServers, do: Query, else: Command

    with {:ok, request} <- module.new(owner, input), do: runner.run(request, caller)
  end

  test "an owner's servers are added, listed and removed, each change recorded as the caller's" do
    jon = caller("acme/@jon/")

    docs = %{
      "name" => "docs",
      "url" => "https://docs.example.com/mcp",
      "auth" => %{"none" => %{}}
    }

    assert {:created,
            %Server{
              name: "docs",
              url: "https://docs.example.com/mcp",
              auth: "none",
              authorization: nil
            } = added} =
             run(AddServer, jon, :person, docs)

    assert AddServer.render(added) == %{"server" => "docs", "connected" => true}

    assert_received {:add, owner, "docs", @jon}
    assert to_string(owner) == "acme/@jon/"

    assert {:ok, [%Server{name: "docs", auth: "none"}] = servers} =
             run(ReadServers, jon, :person, %{})

    assert %{"servers" => [%{"name" => "docs", "auth" => "none"}]} = ReadServers.render(servers)

    assert [{"server.added", %{"type" => "user", "id" => "jon"}} | _] =
             Audit.about("servers/acme/@jon/docs")

    assert {:ok, nil} = run(RemoveServer, jon, :person, %{"name" => "docs"})
    assert {:ok, []} = run(ReadServers, jon, :person, %{})
    assert {"server.removed", _by} = List.last(Audit.about("servers/acme/@jon/docs"))
  end

  test "a server someone signs in to first answers where" do
    crm = %{
      "name" => "crm",
      "url" => "https://mcp.crm.example/mcp",
      "auth" => %{"secret" => %{"name" => "crm-key"}}
    }

    assert {:created,
            %Server{
              name: "crm",
              authorization: %{url: "https://auth.example.com/crm"}
            } = added} =
             run(AddServer, caller("acme/"), :org, crm)

    assert %{"server" => "crm", "connected" => false, "authorization" => %{"url" => _url}} =
             AddServer.render(added)
  end

  test "the seam's refusal is the operation's" do
    docs = %{
      "name" => "docs",
      "url" => "https://docs.example.com/mcp",
      "auth" => %{"none" => %{}}
    }

    {:created, _added} = run(AddServer, caller("acme/"), :org, docs)

    assert {:error, %Error{type: :conflict}} = run(AddServer, caller("acme/"), :org, docs)

    assert {:error, %Error{type: :not_found}} =
             run(RemoveServer, caller("acme/"), :org, %{"name" => "nothing"})

    assert {:error, %Error{type: :invalid}} = AddServer.new(Prefix.parse!("acme/"), %{})
    assert {:error, %Error{type: :invalid}} = RemoveServer.new(Prefix.parse!("acme/"), %{})
  end

  test "adding needs define, and a caller reaches its own owner alone" do
    docs = %{
      "name" => "docs",
      "url" => "https://docs.example.com/mcp",
      "auth" => %{"none" => %{}}
    }

    assert {:error, %Error{type: :forbidden}} =
             run(AddServer, caller("acme/", [:read]), :org, docs)

    assert {:error, %Error{type: :not_found}} =
             Command.run(
               %AddServer{owner: Prefix.parse!("globex/"), name: "docs", fields: docs},
               caller("acme/")
             )
  end

  test "a host that lets nobody add servers answers unsupported" do
    assert {:error, %Error{type: :unsupported}} =
             run(ReadServers, caller("acme/", Grant.actions(), Host.new()), :org, %{})
  end

  test "each operation is in the catalog, with its input's schema" do
    for module <- Catalog.server_queries() ++ Catalog.server_commands() do
      assert %{"type" => "object"} = module.input()
      assert module.name() =~ ~r/^servers\./
    end
  end
end
