defmodule Wardrik.Channels do
  @moduledoc """
  Installs Wardrik's chat apps into people's workspaces, from your app's own pages.

      # 1. Send the person to the chat app
      {:ok, url} =
        Wardrik.Channels.install_url(MyApp.AgentRuntime,
          channel: "slack",
          owner: "acme",
          return_to: "/settings"
        )

      # 2. When the chat app sends them back
      {:ok, installation, next} =
        Wardrik.Channels.installed(MyApp.AgentRuntime,
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

  The channel's adapter, such as `WardrikSlack`, does the work. Returns an error if the adapter
  doesn't support it.
  """

  alias Wardrik.Channel.Installation

  @arities %{install_url: 2, installed: 2, uninstall: 2}

  @doc """
  Returns the URL where someone acting for `:owner` installs the `:channel`'s chat app.

  ## Options

    * `:return_to` - where they're sent once it's installed.
  """
  @spec install_url(atom(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install_url(instance, args) do
    install = %WardrikChannel.Install{
      owner: Keyword.fetch!(args, :owner),
      return_to: args[:return_to]
    }

    adapted(instance, Keyword.fetch!(args, :channel), :install_url, [install])
  end

  @doc """
  Completes an install of the `:channel`'s chat app for `:owner`, from its callback `:query`.

  Returns the installation and where to send the person next.
  """
  @spec installed(atom(), channel: String.t(), owner: String.t(), query: map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def installed(instance, args) do
    install = %WardrikChannel.Install{
      owner: Keyword.fetch!(args, :owner),
      query: Keyword.fetch!(args, :query)
    }

    adapted(instance, Keyword.fetch!(args, :channel), :installed, [install])
  end

  @doc "Uninstalls the `:channel`'s chat app from `:workspace`, and forgets the workspace."
  @spec uninstall(atom(), channel: String.t(), workspace: String.t()) ::
          :ok | {:error, String.t()}
  def uninstall(instance, args),
    do:
      adapted(instance, Keyword.fetch!(args, :channel), :uninstall, [
        Keyword.fetch!(args, :workspace)
      ])

  defp adapted(instance, name, callback, arguments) do
    with {:ok, {adapter, opts}} <- fetched(instance, name),
         :ok <- supports(adapter, callback, name) do
      apply(adapter, callback, arguments ++ [WardrikChannel.channel(adapter, opts)])
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
