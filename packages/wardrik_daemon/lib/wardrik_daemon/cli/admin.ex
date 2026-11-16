defmodule WardrikDaemon.CLI.Admin do
  @moduledoc false

  alias WardrikDaemon.CLI.Browser
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Init
  alias WardrikDaemon.CLI.Table
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Client
  alias WardrikDaemon.Doctor

  @doc "Returns the commands that set Wardrik up and run the daemon."
  @spec commands() :: [Command.t()]
  def commands do
    [
      Init.command(),
      %Command{
        name: "doctor",
        group: "Set up",
        summary: "check what the daemon reads, running or not",
        run: &doctor/3
      },
      %Command{name: "version", group: "Set up", summary: "print the version", run: &version/3},
      %Command{
        name: "completion",
        group: "Set up",
        arguments: "SHELL",
        count: 1,
        summary: "completion for bash, zsh or fish, to install",
        details: [
          "It completes commands and their options, for wardrik and rik:",
          "  wardrik completion bash > ~/.local/share/bash-completion/completions/wardrik",
          "  wardrik completion zsh > \"${fpath[1]}/_wardrik\"",
          "  wardrik completion fish > ~/.config/fish/completions/wardrik.fish"
        ],
        run: &completion/3
      },
      script("serve", "run the daemon here, logging to the terminal"),
      script("start", "run the daemon in the background"),
      script("stop", "stop the daemon"),
      script("pid", "the daemon's process id"),
      script("logs", "follow what the daemon logs"),
      script("service install", "run the daemon as a systemd user service"),
      script("service uninstall", "stop running it as a service"),
      %Command{
        name: "uninstall",
        group: "Daemon",
        switches: [purge: :boolean, yes: :boolean],
        summary: "stop the daemon and remove what install.sh installed",
        details: [
          "The config, keys and store are kept, for a later install.",
          "--purge deletes them too, after asking; --yes doesn't ask."
        ]
      },
      %Command{
        name: "web",
        group: "Daemon",
        switches: [print: :boolean],
        summary: "open the web dashboard in your browser, signed in",
        details: [
          "It opens a link that works once, within two minutes, and prints it too. The session",
          "it starts lasts 12 hours. --print only prints it. BROWSER names the browser.",
          "The dashboard is at /web on the daemon's port. web.enabled: false turns it off."
        ],
        run: &web/3
      },
      %Command{
        name: "status",
        group: "Daemon",
        summary: "where the daemon runs, and how many agents each node holds",
        run: &status/3
      },
      %Command{
        name: "reload",
        group: "Daemon",
        arguments: "[AGENT...]",
        count: {0, :any},
        summary: "read the agent files again, on every node",
        details: [
          "AGENTs reload only those. wardrik doctor says which files don't read."
        ],
        run: &reload/3
      },
      %Command{
        name: "audit",
        group: "Daemon",
        summary: "what people changed, oldest first",
        run: &audit/3
      }
    ]
  end

  defp script(name, summary), do: %Command{name: name, group: "Daemon", summary: summary}

  defp doctor([], _flags, cx) do
    {:ok, checks} =
      Terminal.spinning(cx.terminal, "Checking", fn -> {:ok, Doctor.run(cx.env)} end)

    checks
    |> Doctor.lines()
    |> Enum.each(&Context.puts(cx, &1))

    case Doctor.failed(checks) do
      0 -> :ok
      failed -> {:error, "#{failed} of the checks failed."}
    end
  end

  defp version([], _flags, cx),
    do: Context.puts(cx, "wardrik #{Application.spec(:wardrik_daemon, :vsn)}")

  defp web([], flags, cx) do
    with {:ok, client} <- Context.client(cx),
         {:ok, %{"url" => url} = answer} <-
           client
           |> Client.run("tokens.web", %{})
           |> Context.called(),
         do: Context.show(cx, answer, fn _answer -> link(cx, url, flags[:print]) end)
  end

  defp link(cx, url, true), do: Context.puts(cx, url)

  defp link(cx, url, _print) do
    case Browser.open(cx.env, url) do
      :ok ->
        Context.puts(cx, "Opened the dashboard in your browser. If it didn't open, this link")
        Context.puts(cx, "signs you in, once, within two minutes:")
        Context.puts(cx, Owl.Data.tag(url, :cyan))

      {:error, why} ->
        Context.puts(cx, "Open this link within two minutes to sign in. It works once:")
        Context.puts(cx, Owl.Data.tag(url, :cyan))
        forward(cx, why, URI.parse(url))
    end
  end

  # Over SSH the daemon's own address only answers here, so the person's machine forwards to it.
  defp forward(cx, :remote, %URI{host: host, port: port})
       when host in ["localhost", "127.0.0.1"] do
    {:ok, here} = :inet.gethostname()

    Context.puts(cx, [
      "From your machine, forward its port first: ",
      Owl.Data.tag("ssh -L #{port}:localhost:#{port} #{here}", :cyan)
    ])
  end

  defp forward(_cx, _why, _url), do: :ok

  defp status([], _flags, cx) do
    with {:ok, client} <- Context.client(cx),
         {:ok, %{"nodes" => nodes, "asleep" => asleep} = answer} <-
           client
           |> Client.run("deployment.nodes", %{})
           |> Context.called(),
         do: Context.show(cx, answer, fn _answer -> nodes(cx, client.url, nodes, asleep) end)
  end

  defp nodes(cx, url, nodes, asleep) do
    Context.puts(cx, ["Wardrik runs at ", Owl.Data.tag(url, :cyan), "."])
    rows = for node <- nodes, do: [node["name"], node["agents"]]
    Table.print(cx, header: ["NODE", "AGENTS"], rows: rows, empty: "No nodes answer.")
    Context.puts(cx, Owl.Data.tag("#{asleep} asleep", :light_black))
  end

  defp completion([shell], _flags, _cx) do
    case WardrikDaemon.CLI.Completion.script(shell, WardrikDaemon.CLI.commands()) do
      {:ok, script} -> IO.write(script)
      :error -> {:error, "There's no completion for #{shell}: it's bash, zsh or fish."}
    end
  end

  defp reload(agents, _flags, cx) do
    with {:ok, input} <- covering(cx, agents),
         {:ok, answer} <-
           Terminal.spinning(cx.terminal, "Reading the agent files", fn ->
             Context.call(cx, "deployment.reload", input)
           end),
         do: Context.show(cx, answer, &reloaded(cx, &1))
  end

  defp covering(_cx, []), do: {:ok, %{}}

  defp covering(cx, agents) do
    with {:ok, ids} <- Context.agents(cx, agents), do: {:ok, %{"agents" => ids}}
  end

  defp reloaded(cx, %{"reloaded" => nodes} = answer) do
    Context.puts(cx, "Read the agent files again on #{Enum.join(nodes, ", ")}.")

    for problem <- Map.get(answer, "problems", []),
        do: Context.puts(cx, [Owl.Data.tag("! ", :yellow), "Wardrik ", problem])
  end

  defp audit([], _flags, cx) do
    with {:ok, %{"events" => events} = answer} <- Context.call(cx, "audit.list", %{}) do
      Table.show(cx, answer,
        header: ["WHEN", "WHAT", "WHO", "ON"],
        rows: for(event <- events, do: change(event)),
        empty: "Nothing has changed yet."
      )
    end
  end

  defp change(event),
    do: [event["time"], event["type"], get_in(event, ["data", "actor", "id"]), event["subject"]]
end
