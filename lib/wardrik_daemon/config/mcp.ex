defmodule WardrikDaemon.Config.MCP do
  @moduledoc """
  Reads `config.yaml`'s `mcp`: the MCP servers agents may call, each by a name of your own.

      mcp:
        github:
          url: https://api.githubcopilot.com/mcp/
          credential: github
          only: [list_commits, get_commit]
        notes:
          command: npx
          args: [-y, notes-mcp]
          timeout: 30

  A server has a `command` or a `url`, not both:

    * `command`, `args`, `env` - the program to run, over stdio.
    * `url`, `headers` - its full endpoint, as `https://mcp.linear.app/mcp`, reached over
      streamable HTTP as given.

  It takes `WardrikMCP.Server`'s options too, but `transport` and `owner`, with two written
  differently:

    * `credential` - `credential_name`, the credential each principal reaches it with.
    * `timeout` - seconds a call may take, not milliseconds.

  These are the deployment's servers. Orgs and people add their own. See `WardrikDaemon.Servers`.
  """

  alias WardrikDaemon.Config.Options

  @transport ~w(command args env url headers)
  @managed ~w(transport owner credential_name)

  @doc "Returns the servers `section` names, as `WardrikMCP` takes them, or the key that doesn't read."
  @spec read(map()) :: {:ok, keyword()} | {:error, String.t()}
  def read(section) do
    Options.loaded([WardrikMCP.Server])
    Options.each(section, &server/2)
  end

  defp server(name, server) when is_map(server) do
    path = "mcp.#{name}"
    {transport, own} = Map.split(server, @transport)

    with :ok <- managed(own, path),
         {:ok, transport} <- transport(transport, path),
         {:ok, own} <- Options.convert(renamed(own), [], path),
         opts = [transport: transport] ++ Enum.map(own, &option/1),
         {:ok, _server} <- Options.built(fn -> WardrikMCP.Server.new!(name, opts) end, path) do
      {:ok, opts}
    end
  end

  defp server(name, _server),
    do: {:error, "mcp.#{name}: is a server's keys, with a command or a url"}

  defp managed(own, path) do
    case Enum.find(@managed, &Map.has_key?(own, &1)) do
      nil -> :ok
      "credential_name" -> {:error, "#{path}.credential_name: is written credential"}
      key -> {:error, "#{path}.#{key}: is the daemon's to set"}
    end
  end

  defp renamed(%{"credential" => name} = own),
    do: own |> Map.delete("credential") |> Map.put("credential_name", name)

  defp renamed(own), do: own

  defp transport(%{"url" => _url, "command" => _command}, path),
    do: {:error, "#{path}: has a url or a command, not both"}

  defp transport(%{"url" => url} = server, _path),
    do: {:ok, {:streamable_http, url: url, headers: Map.get(server, "headers", %{})}}

  defp transport(%{"command" => command} = server, _path),
    do:
      {:ok,
       {:stdio,
        command: command, args: Map.get(server, "args", []), env: Map.get(server, "env", %{})}}

  defp transport(_server, path),
    do: {:error, "#{path}: has a command to run it, or a url to reach it at"}

  defp option({:timeout, seconds}) when is_number(seconds), do: {:timeout, round(seconds * 1000)}
  defp option({:cost, cost}) when is_map(cost), do: {:cost, Enum.map(cost, &cost/1)}
  defp option(option), do: option

  defp cost({kind, amount}), do: {Options.atom(kind), amount}
end
