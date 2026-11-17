defmodule Wardrik.Channels do
  @moduledoc """
  Installs chat apps into people's workspaces, from your app's pages.

      # 1. Send the person to the chat app
      {:ok, url} =
        Wardrik.Channels.install_url(MyApp.AgentRuntime,
          channel: "slack",
          owner: "acme",
          return_to: "/settings"
        )

      # 2. When the chat app sends them back
      {:ok, installation, next} =
        Wardrik.Channels.complete_install(MyApp.AgentRuntime,
          channel: "slack",
          owner: "acme",
          query: params
        )

      # 3. To remove it
      :ok =
        Wardrik.Channels.uninstall(MyApp.AgentRuntime,
          channel: "slack",
          workspace: installation.workspace
        )

      # The workspaces an owner added, for your resolver's `:channels`
      Wardrik.Channels.list_installations(MyApp.AgentRuntime, channel: "slack", owner: "acme")

  `:owner` is whatever your app calls who installs it. The adapter, such as `WardrikSlack`, does
  the work, and returns an error if it can't.
  """

  alias Wardrik.Channel.Installation

  @arities %{install_url: 2, complete_install: 2, uninstall: 2}

  @doc """
  Returns the URL that installs `:channel`'s chat app for `:owner`.

  ## Options

    * `:return_to` - where to send them after.
  """
  @spec install_url(atom(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install_url(instance, args) do
    install = %Wardrik.Chat.Install{
      owner: Keyword.fetch!(args, :owner),
      return_to: args[:return_to]
    }

    adapt(instance, Keyword.fetch!(args, :channel), :install_url, [install])
  end

  @doc """
  Completes an install from its callback `:query`. Returns the installation and where to go next.
  """
  @spec complete_install(atom(), channel: String.t(), owner: String.t(), query: map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def complete_install(instance, args) do
    install = %Wardrik.Chat.Install{
      owner: Keyword.fetch!(args, :owner),
      query: Keyword.fetch!(args, :query)
    }

    adapt(instance, Keyword.fetch!(args, :channel), :complete_install, [install])
  end

  @doc "Uninstalls `:channel`'s chat app from `:workspace`."
  @spec uninstall(atom(), channel: String.t(), workspace: String.t()) ::
          :ok | {:error, String.t()}
  def uninstall(instance, args),
    do:
      adapt(instance, Keyword.fetch!(args, :channel), :uninstall, [
        Keyword.fetch!(args, :workspace)
      ])

  @doc """
  Returns `:channel`'s installations for `:owner`, or `[]`.
  """
  @spec list_installations(atom(), channel: String.t(), owner: String.t()) :: [Installation.t()]
  def list_installations(instance, args) do
    case fetch(instance, Keyword.fetch!(args, :channel)) do
      {:ok, {adapter, opts}} ->
        channel = Wardrik.Chat.channel(adapter, opts)
        Wardrik.Chat.Channel.list_installations(channel, Keyword.fetch!(args, :owner))

      {:error, _why} ->
        []
    end
  end

  defp adapt(instance, name, callback, arguments) do
    with {:ok, {adapter, opts}} <- fetch(instance, name),
         :ok <- supports(adapter, callback, name) do
      apply(adapter, callback, arguments ++ [Wardrik.Chat.channel(adapter, opts)])
    end
  end

  defp fetch(instance, name) do
    case Wardrik.Operations.Channels.fetch(instance, name) do
      {:ok, channel} -> {:ok, channel}
      :error -> {:error, "There's no channel #{name} here."}
    end
  end

  defp supports(adapter, callback, name) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, callback, Map.fetch!(@arities, callback)),
      do: :ok,
      else: {:error, "The channel #{name} isn't added to workspaces this way."}
  end
end
