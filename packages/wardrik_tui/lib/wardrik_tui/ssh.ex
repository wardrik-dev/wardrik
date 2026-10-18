defmodule WardrikTUI.SSH do
  @moduledoc """
  The TUI as an SSH session: every client that connects gets `WardrikTUI.App` on
  a terminal of its own, over the fleet this node runs in. It is a
  `Termite.SSH` entrypoint:

      {Termite.SSH,
       port: 2222,
       auth: {:public_key, verifier},
       system_dir: host_key_dir,
       entrypoint: {WardrikTUI.SSH, org: "acme", host: host}}

  A session opens on the first agent the fleet runs, in the order of their
  IDs, and the fleet panel moves it to any other. Where the fleet runs none,
  it starts an assistant for whoever connected, `<org>/@<username>/assistant`
  in `:org`; for a user name that cannot be an ID's segment, the org's own
  `<org>/assistant`. `:org` is also the org of an agent a person names
  without one; see `WardrikTUI.App.server_opts/1`.

  An agent a session starts, that assistant or one `/spawn` names, starts as
  `Wardrik.agent_spawn/3` starts any: on the definition the host keeps of
  it, or one the host's `Wardrik.Definition` creates, so every surface starts
  the same agent. Whoever connected acts as the `:ssh` principal of their
  user name, with the token the host's `Wardrik.Issuer` issues them, on the
  `Wardrik.Host` the entrypoint's `:host` names.

  Breeze starts the session's terminal itself, from the options
  `Termite.SSH.Session.terminal_opts/1` gives, so the keys the client types
  reach the view. Quitting ends the session and nothing else. Copying goes to
  the client's clipboard, through `WardrikTUI.Clipboard.osc52/1`, and a draft is
  not edited in `$VISUAL`, which would run on the server.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Fleet

  @doc "Starts a session for `opts[:session]`, and answers its pid."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)
    org = Keyword.get(opts, :org)
    host = Keyword.fetch!(opts, :host)
    principal = Wardrik.Principal.new(:ssh, to_string(session.username))
    as = Wardrik.as(host, principal)

    with {:ok, id} <- attach(session.username, org, as) do
      start_opts = [
        agent: id,
        agent_id: id,
        org: org,
        host: host,
        principal: principal,
        model: model(as, id),
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

  defp attach(username, org, as) do
    {:ok, members} = Wardrik.agents_list(as, Prefix.all())

    case choose(members, username, org) do
      {:attach, id} ->
        {:ok, id}

      {:start, id} ->
        case Wardrik.agent_spawn(as, id) do
          {:ok, _answer} -> {:ok, id}
          {:error, %Error{message: message}} -> {:error, message}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  The agent a session for `username` opens on, given the fleet's `members`:
  `{:attach, id}` for the first of them by ID, or `{:start, id}` for the
  assistant to start in `org` where there are none. With no agents and no
  `org`, `{:error, message}`.
  """
  @spec choose([Fleet.Member.t()], String.t() | charlist(), String.t() | nil) ::
          {:attach | :start, AgentID.t()} | {:error, String.t()}
  def choose(members, username, org) do
    case Enum.sort_by(members, &to_string(&1.id)) do
      [first | _rest] -> {:attach, first.id}
      [] -> assistant(to_string(username), org)
    end
  end

  defp assistant(username, org) do
    user = if AgentID.segment?(username), do: username

    with {:ok, id} <- AgentID.new("assistant", org: org, user: user), do: {:start, id}
  end

  defp model(as, id) do
    case Wardrik.agent_read(as, id) do
      {:ok, %{status: %{model: model}}} -> model
      {:error, %Error{type: :not_found}} -> ""
    end
  end
end
