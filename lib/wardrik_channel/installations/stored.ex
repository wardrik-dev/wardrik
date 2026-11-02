defmodule WardrikChannel.Installations.Stored do
  @moduledoc """
  Keeps installations in Wardrik, for one app added to many workspaces.

      slack: {WardrikSlack, installations: :stored, ...}

  Each workspace's owner goes in Wardrik's store. Its token is sealed in the vault, as
  a secret of the owner's. Wardrik needs `:keys` to seal tokens. Without them, saving fails and no
  installation is found.
  """

  @behaviour Wardrik.Channel.Installations

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Installations.Request
  alias WardrikCore.Principal
  alias WardrikVault.Secret

  @impl Wardrik.Channel.Installations
  def fetch(%Request{channel: channel, workspace: workspace}, config) do
    with %{"owner" => owner} <-
           WardrikStore.get(store(config), key(channel, workspace)),
         {:ok, token} <- sealed(config, owner, secret(channel, workspace)) do
      {:ok,
       %Installation{
         channel: channel,
         workspace: workspace,
         owner: owner,
         token: token
       }}
    else
      _missing -> :error
    end
  end

  @impl Wardrik.Channel.Installations
  def owned(%Request{channel: channel, owner: owner}, config) do
    prefix = key(channel, "")
    store = store(config)

    for key <- WardrikStore.keys(store, prefix),
        %{"owner" => ^owner} <- [WardrikStore.get(store, key)],
        {:ok, installation} <- [
          fetch(
            %Request{channel: channel, workspace: String.replace_prefix(key, prefix, "")},
            config
          )
        ],
        do: installation
  end

  @impl Wardrik.Channel.Installations
  def put(
        %Installation{channel: channel, workspace: workspace, owner: owner} = installation,
        config
      ) do
    kept = %{"owner" => owner}

    with {:ok, _sealed} <- seal(config, owner, secret(channel, workspace), installation.token),
         {:ok, _vsn} <- WardrikStore.put(store(config), key(channel, workspace), kept) do
      :ok
    else
      {:error, reason} -> {:error, "#{channel} wasn't kept for #{workspace}: #{inspect(reason)}"}
    end
  end

  @impl Wardrik.Channel.Installations
  def delete(%Request{channel: channel, workspace: workspace}, config) do
    case WardrikStore.get(store(config), key(channel, workspace)) do
      %{"owner" => owner} ->
        :ok = unseal(config, owner, secret(channel, workspace))
        WardrikStore.delete(store(config), key(channel, workspace))

      nil ->
        :ok
    end
  end

  defp sealed(config, owner, name), do: config |> vault() |> sealed_in(owner, name)

  defp sealed_in(nil, _owner, _name), do: {:error, :no_keys}

  defp sealed_in(vault, owner, name),
    do: WardrikVault.fetch(vault, %Principal{id: owner}, name, kind: :token)

  defp seal(config, owner, name, token), do: config |> vault() |> seal_in(owner, name, token)

  defp seal_in(nil, _owner, _name, _token), do: {:error, :no_keys}

  defp seal_in(vault, owner, name, token) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: token}
    WardrikVault.put(vault, secret, kind: :token)
  end

  defp unseal(config, owner, name), do: config |> vault() |> unseal_in(owner, name)

  defp unseal_in(nil, _owner, _name), do: :ok
  defp unseal_in(vault, owner, name), do: WardrikVault.delete(vault, %Principal{id: owner}, name)

  defp vault(config), do: Keyword.get(config, :vault)

  defp store(config), do: Keyword.fetch!(config, :store)
  defp key(channel, workspace), do: "installations/#{channel}/#{workspace}"
  defp secret(channel, workspace), do: "#{channel}:#{workspace}"
end
