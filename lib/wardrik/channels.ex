defmodule Wardrik.Channels do
  @moduledoc """
  Adds a Wardrik's chat apps to the workspaces people use, for your app's own pages: where to send
  someone to add one, what to do once the chat app sends them back, and taking it out again. The
  channel's adapter does each, where it can, such as `WardrikSlack`.

      {:ok, url} = Wardrik.Channels.install_url(MyApp.Wardrik, "slack", "acme", return_to: "/settings")
  """

  alias Wardrik.Channel.Installation

  @arities %{install_url: 3, installed: 3, uninstall: 2}

  @doc """
  Returns where someone acting for `owner` adds the channel `name`'s chat app to a workspace of
  theirs. Takes `:return_to`, where they're sent once it's added.
  """
  @spec install_url(atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def install_url(instance, name, owner, opts \\ []),
    do: adapted(instance, name, :install_url, &[&1, owner, opts])

  @doc """
  Adds the channel `name`'s chat app to the workspace it sent someone acting for `owner` back from,
  given the query it sent. Returns the installation, with the workspace's name, and where to send
  them next.
  """
  @spec installed(atom(), String.t(), String.t(), map()) ::
          {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}
  def installed(instance, name, owner, query),
    do: adapted(instance, name, :installed, &[&1, owner, query])

  @doc "Takes the channel `name`'s chat app out of `workspace`, and forgets the workspace."
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
