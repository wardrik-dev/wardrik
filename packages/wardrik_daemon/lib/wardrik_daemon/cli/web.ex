defmodule WardrikDaemon.CLI.Web do
  @moduledoc false

  alias WardrikDaemon.CLI.Browser
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.Client

  @doc "Returns the command that opens the dashboard's chat in the browser."
  @spec command() :: Command.t()
  def command do
    %Command{
      name: "web",
      group: "Daemon",
      arguments: "[AGENT]",
      count: {0, :any},
      switches: [print: :boolean],
      summary: "chat in your browser, signed in to the web dashboard",
      details: [
        "It opens the chat with AGENT, or the chat page, and prints the link too. The link works",
        "once, within two minutes; the session lasts web.session_days, 30 by default, from the",
        "last use. --print only prints the link.",
        "BROWSER names the browser. web.enabled: false in config.yaml turns the dashboard off."
      ],
      run: &run/3
    }
  end

  @doc """
  Opens the chat with the agent `id` in the browser, signed in. Over SSH, or without a display, it
  prints the link to open instead.
  """
  @spec open(Context.t(), String.t()) :: :ok | {:error, String.t()}
  def open(cx, id), do: linked(cx, %{"agent" => id}, false)

  defp run([], flags, cx), do: linked(cx, %{}, flags[:print])

  defp run([name], flags, cx) do
    with {:ok, id} <- Context.agent(cx, name), do: linked(cx, %{"agent" => id}, flags[:print])
  end

  defp run(_names, _flags, _cx), do: {:error, "web opens one agent's chat at most."}

  defp linked(cx, input, print) do
    with {:ok, client} <- Context.client(cx),
         {:ok, %{"url" => url} = answer} <-
           client
           |> Client.run("tokens.web", input)
           |> Context.called(),
         do: Context.show(cx, answer, fn _answer -> link(cx, url, print) end)
  end

  defp link(cx, url, true), do: Context.puts(cx, url)

  defp link(cx, url, _print) do
    case Browser.open(cx.env, url) do
      :ok ->
        Context.puts(cx, "Opened the chat in your browser. If it didn't open, this link signs")
        Context.puts(cx, "you in, once, within two minutes:")
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
end
