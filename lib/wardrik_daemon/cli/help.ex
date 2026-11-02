defmodule WardrikDaemon.CLI.Help do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context

  @groups [
    "Set up",
    "Agents",
    "Approvals",
    "Triggers",
    "MCP servers",
    "Notify targets",
    "OAuth apps",
    "Connections",
    "Vault",
    "Tokens",
    "Daemon"
  ]
  @column 32

  @doc "Writes every command, by group."
  @spec all(Context.t(), [Command.t()]) :: :ok
  def all(cx, commands) do
    Context.puts(cx, [
      "Usage: ",
      Owl.Data.tag("#{cx.program} COMMAND [ARGUMENTS] [--json]", :bright)
    ])

    for group <- @groups,
        listed = Enum.filter(commands, &(&1.group == group)),
        listed != [] do
      Context.puts(cx, "")
      listing(cx, group, listed)
    end

    Context.puts(cx, "")
    Context.puts(cx, Owl.Data.tag(shortcuts(commands), :light_black))

    Context.puts(
      cx,
      Owl.Data.tag(
        "#{cx.program} help COMMAND, or COMMAND --help, says more about one.",
        :light_black
      )
    )
  end

  @doc "Writes the commands under `namespace`, as `agent`."
  @spec namespace(Context.t(), String.t(), [Command.t()]) :: :ok
  def namespace(cx, namespace, commands) do
    Context.puts(cx, [
      "Usage: ",
      Owl.Data.tag("#{cx.program} #{namespace} COMMAND [ARGUMENTS] [--json]", :bright)
    ])

    Context.puts(cx, "")
    listing(cx, hd(commands).group, commands)
  end

  @doc "Writes how `command` is typed, what it does, and its details."
  @spec command(Context.t(), Command.t()) :: :ok
  def command(cx, %Command{} = command) do
    Context.puts(cx, ["Usage: ", Owl.Data.tag("#{cx.program} #{Command.usage(command)}", :bright)])

    Context.puts(cx, "")
    Context.puts(cx, String.capitalize(command.summary) <> ".")
    Enum.each(command.details, &Context.puts(cx, &1))
    also(cx, command)
  end

  defp also(_cx, %Command{shortcut: nil}), do: :ok

  defp also(cx, %Command{shortcut: shortcut}),
    do: Context.puts(cx, Owl.Data.tag("Also: #{cx.program} #{shortcut}", :light_black))

  defp listing(cx, group, commands) do
    Context.puts(cx, Owl.Data.tag(group, [:bright, :cyan]))

    Enum.each(commands, &Context.puts(cx, listed(&1)))
  end

  defp listed(command) do
    typed = String.pad_trailing(String.trim("#{command.name} #{command.arguments}"), @column)
    ["  ", Owl.Data.tag(typed, :cyan), " ", command.summary]
  end

  defp shortcuts(commands) do
    shortcuts =
      for %Command{shortcut: shortcut, name: name} <- commands,
          shortcut,
          do: "#{shortcut} for #{name}"

    ["Shortcuts: ", Enum.intersperse(shortcuts, ", "), "."]
  end
end
