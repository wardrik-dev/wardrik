defmodule Wardrik.Channels do
  @moduledoc """
  Installs Wardrik's chat apps into people's workspaces, from your app's own pages.

      # 1. Send the person to the chat app
      {:ok, url} = Wardrik.Channels.install_url(MyApp.AgentRuntime, "slack", "acme", return_to: "/settings")

      # 2. When the chat app sends them back
      {:ok, installation, next} = Wardrik.Channels.installed(MyApp.AgentRuntime, "slack", "acme", params)

      # 3. To remove it
      :ok = Wardrik.Channels.uninstall(MyApp.AgentRuntime, "slack", installation.workspace)

  The channel's adapter, such as `WardrikSlack`, does the work. Returns an error if the adapter
  doesn't support it.
  """

  alias Wardrik.Channel.Installation

  @arities %{install_url: 3, installed: 3, uninstall: 2}

  @doc """
  Returns the URL where someone acting for `owner` installs the channel `name`'s chat app.

  ## Options

    * `:return_to` - where they're sent once it's installed.
  """
  @spec install_url(atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def install_url(instance, name, owner, opts \\ []),
    do: adapted(instance, name, :install_url, &[&1, owner, opts])

  @doc """
  Completes an install from the chat app's callback `query`.

  Returns the installation and where to send the person next.
  """
  @spec installed(atom(), String.t(), String.t(), map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def installed(instance, name, owner, query),
    do: adapted(instance, name, :installed, &[&1, owner, query])

  @doc "Uninstalls the channel `name`'s chat app from `workspace`, and forgets the workspace."
  @spec uninstall(atom(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def uninstall(instance, name, workspace),
    do: adapted(instance, name, :uninstall, &[&1, workspace])

  defp adapted(instance, name, callback, arguments) do
    with {:ok, {adapter, opts}} <- fetched(instance, name),
         :ok <- supports(adapter, callback, name) do
      apply(adapter, callback, arguments.(WardrikChannel.channel(adapter, opts)))
    end
  end

  defp fetched(instance, name) do
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
