defmodule WardrikDaemon.Config.MCP do
  @moduledoc """
  Reads `config.yaml`'s `mcp`: the MCP servers agents may call.

      mcp:
        github:
          url: https://api.githubcopilot.com/mcp/
          credential: github
          only: [list_commits, get_commit]
        notes:
          command: npx
          args: [-y, notes-mcp]
          timeout: 30

    * A server has `command` (with `args`, `env`) or `url` (with `headers`), not both.
    * `url` is the full endpoint, used as given. A server whose `credential` gives each user's
      URL, as a broker may, leaves it out.
    * It takes `Wardrik.MCP.Server`'s options too, except `transport` and `owner`.
    * `credential` is `credential_name`. `timeout` is in seconds.
    * Orgs and people add their own servers. See Wardrik's `servers.*` operations.
  """

  alias WardrikDaemon.Config.Options

  @transport ~w(command args env url headers)
  @managed ~w(transport owner credential_name)

  @doc "Returns the servers `section` names, as `Wardrik.MCP` takes them, or the key that doesn't read."
  @spec read(map()) :: {:ok, keyword()} | {:error, String.t()}
  def read(section) do
    Options.load_modules([Wardrik.MCP.Server])
    Options.each(section, &server/2)
  end

  defp server(name, server) when is_map(server) do
    path = "mcp.#{name}"
    {transport, own} = Map.split(server, @transport)

    with :ok <- manage(own, path),
         {:ok, transport} <- transport(transport, Map.has_key?(own, "credential"), path),
         {:ok, own} <-
           own
           |> rename()
           |> Options.convert([], path),
         opts = [transport: transport] ++ Enum.map(own, &option/1),
         {:ok, _server} <-
           Options.call_builder(fn -> Wardrik.MCP.Server.new!(name, opts) end, path) do
      {:ok, opts}
    end
  end

  defp server(name, _server),
    do: {:error, "mcp.#{name}: is a server's keys, with a command or a url"}

  defp manage(own, path) do
    case Enum.find(@managed, &Map.has_key?(own, &1)) do
      nil -> :ok
      "credential_name" -> {:error, "#{path}.credential_name: is written credential"}
      key -> {:error, "#{path}.#{key}: is the daemon's to set"}
    end
  end

  defp rename(%{"credential" => name} = own) do
    own
    |> Map.delete("credential")
    |> Map.put("credential_name", name)
  end

  defp rename(own), do: own

  defp transport(%{"url" => _url, "command" => _command}, _credential, path),
    do: {:error, "#{path}: has a url or a command, not both"}

  defp transport(%{"url" => url} = server, _credential, _path),
    do: {:ok, {:streamable_http, url: url, headers: Map.get(server, "headers", %{})}}

  defp transport(%{"command" => command} = server, _credential, _path),
    do:
      {:ok,
       {:stdio,
        command: command, args: Map.get(server, "args", []), env: Map.get(server, "env", %{})}}

  defp transport(server, true, _path),
    do: {:ok, {:streamable_http, headers: Map.get(server, "headers", %{})}}

  defp transport(_server, false, path),
    do:
      {:error,
       "#{path}: has a command to run it, a url to reach it at, or a credential that gives the url"}

  defp option({:timeout, seconds}) when is_number(seconds), do: {:timeout, round(seconds * 1000)}
  defp option({:cost, cost}) when is_map(cost), do: {:cost, Enum.map(cost, &cost/1)}
  defp option(option), do: option

  defp cost({kind, amount}), do: {Options.atom(kind), amount}
end
