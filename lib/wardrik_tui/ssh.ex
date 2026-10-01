defmodule WardrikTUI.SSH do
  @moduledoc """
  The TUI as an SSH session: every client that connects gets `WardrikTUI.App` on
  a terminal of its own, over the fleet this node runs in. It is a
  `Termite.SSH` entrypoint:

      {Termite.SSH,
       port: 2222,
       auth: {:public_key, verifier},
       system_dir: host_key_dir,
       entrypoint: {WardrikTUI.SSH, spawn_opts: []}}

  A session opens on the first agent the fleet runs, in the order of their
  keys, and the fleet panel moves it to any other. Where the fleet runs none,
  it starts an assistant for whoever connected, `<org>/@<username>/assistant`
  in the deployment's org, with `:spawn_opts`; for a user name that cannot be
  a key's segment, the org's own `<org>/assistant`.

  Breeze starts the session's terminal itself, from the options
  `Termite.SSH.Session.terminal_opts/1` gives, so the keys the client types
  reach the view. Quitting ends the session and nothing else. Copying goes to
  the client's clipboard, through `WardrikTUI.Clipboard.osc52/1`, and a draft is
  not edited in `$VISUAL`, which would run on the server.
  """

  alias Wardrik.Agent
  alias Wardrik.Fleet

  @doc "Starts a session for `opts[:session]`, and answers its pid."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)
    spawn_opts = Keyword.get(opts, :spawn_opts, [])

    with {:ok, key} <- attach(session.username, spawn_opts) do
      start_opts = [
        agent: key,
        agent_id: key,
        spawn_opts: spawn_opts,
        principal: %Wardrik.Principal{type: :ssh, id: to_string(session.username)},
        model: model(key),
        clipboard: WardrikTUI.Clipboard.osc52(&write(session, &1)),
        editor: fn _draft, _context -> {:error, :remote} end
      ]

      Breeze.Server.start_link(
        [terminal_opts: Termite.SSH.Session.terminal_opts(session)] ++
          WardrikTUI.App.server_opts(start_opts)
      )
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  # Written to the session's channel as it stands, beside the frames Breeze
  # draws there.
  defp write(session, string),
    do: Termite.SSH.Adapter.write(%Termite.SSH.Adapter{channel_pid: session.channel_pid}, string)

  defp attach(username, spawn_opts) do
    case choose(Fleet.list(), username) do
      {:attach, key} -> {:ok, key}
      {:start, key} -> with {:ok, _pid} <- Fleet.spawn(key, spawn_opts), do: {:ok, key}
    end
  end

  @doc """
  The agent a session for `username` opens on, given the fleet's `members`:
  `{:attach, key}` for the first of them by key, or `{:start, key}` for the
  assistant to start where there are none.
  """
  @spec choose([Fleet.Member.t()], String.t() | charlist()) :: {:attach | :start, String.t()}
  def choose(members, username) do
    case Enum.sort_by(members, & &1.key) do
      [first | _rest] -> {:attach, first.key}
      [] -> {:start, Fleet.key("assistant", whose(to_string(username)))}
    end
  end

  defp whose(username), do: if(Fleet.segment?(username), do: [user: username], else: [])

  defp model(key) do
    case Agent.status(key) do
      %{model: model} -> model
      {:error, :not_found} -> ""
    end
  end
end
