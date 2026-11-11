defmodule WardrikDaemon.Web.ConfigLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Dirs

  # Values under these keys are hidden unless they reference a secret, as ${NAME}.
  @secret ~r/^(\s*-?\s*[\w-]*(secret|token|password|passphrase|api_key|key)s?\s*:\s*)(?!\$\{)(\S.*)$/i

  @impl true
  def mount(_params, _session, socket) do
    daemon = socket.endpoint.config(:daemon)

    socket =
      assign(socket,
        page_title: "Configuration",
        daemon: daemon,
        files: [],
        error: nil,
        reference: "${NAME}"
      )

    case Allowed.authorized(socket.assigns.scope, "config.read", {:deployment, "config"}) do
      :ok -> {:ok, assign(socket, files: files(daemon.dirs))}
      {:error, error} -> {:ok, assign(socket, error: error.message)}
    end
  end

  defp files(dirs) do
    config = Dirs.config(dirs, "config.yaml")
    policies = dirs |> Dirs.config("policies/*.yaml") |> Path.wildcard() |> Enum.sort()

    for path <- [config | policies],
        File.exists?(path),
        do: {path, path |> File.read!() |> hidden()}
  end

  defp hidden(text),
    do:
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &Regex.replace(@secret, &1, "\\1•••••• (hidden)"))

  @impl true
  def render(assigns) do
    ~H"""
    <.head
      title="Configuration"
      lead="The daemon's settings, read from config.yaml and the policy files. This page is read-only."
    />
    <div :if={@error} class="flash error" role="alert">{@error}</div>
    <div :if={!@error} class="card">
      <div class="body">
        <p style="margin: 0">
          To change a setting, edit the file on the server, then run <code>wardrik reload</code>.
        </p>
        <p style="margin: 8px 0 0">
          Secrets written directly in a file are hidden here. To keep them out of the file, write
          <code>{@reference}</code>
          instead. The daemon then reads the value from the vault or the environment.
        </p>
      </div>
    </div>
    <div :for={{path, text} <- @files} class="card">
      <header><code>{path}</code></header>
      <pre class="json config">{text}</pre>
    </div>
    """
  end
end
