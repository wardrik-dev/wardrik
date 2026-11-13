defmodule Wardrik.Vault.Lookup do
  @moduledoc false

  alias WardrikCore.Principal

  require Logger

  @spec fetch(atom() | Wardrik.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch(instance, args) do
    {owner, name, opts} = named(args)

    with {:ok, wardrik} <- sealing(instance) do
      vault = Wardrik.vault(wardrik)
      Wardrik.Vault.fetch(vault, principal(owner), name, opts)
    end
  end

  @spec list(atom() | Wardrik.t()) :: [{String.t(), String.t(), Wardrik.Vault.kind()}]
  def list(instance) do
    case sealing(instance) do
      {:ok, wardrik} ->
        wardrik
        |> Wardrik.vault()
        |> Wardrik.Vault.list()

      {:error, :no_keys} ->
        []
    end
  end

  @doc "Returns whether `:owner` holds the secret `:name` sealed as `:kind`. Needs no key."
  @spec holds?(atom() | Wardrik.t(), keyword()) :: boolean()
  def holds?(instance, args) do
    {owner, name, args} = named(args)
    {owner, name, Keyword.fetch!(args, :kind)} in list(instance)
  end

  @doc """
  Returns `opts` with each `{:secret, name}` read from the deployment's secrets, or `nil`.
  """
  @spec resolved(Wardrik.t(), String.t(), keyword() | map()) :: keyword() | map()
  def resolved(wardrik, what, opts) when is_map(opts),
    do: Map.new(opts, &resolved_pair(wardrik, what, &1))

  def resolved(wardrik, what, opts) when is_list(opts),
    do: Enum.map(opts, &resolved_pair(wardrik, what, &1))

  defp resolved_pair(wardrik, what, {key, {:secret, name} = ref}) when is_binary(name) do
    case value(wardrik, ref) do
      {:ok, value} ->
        {key, value}

      {:error, _reason} ->
        Logger.warning(
          "#{what}'s #{key} names the secret #{name}, which the deployment hasn't sealed"
        )

        {key, nil}
    end
  end

  defp resolved_pair(_wardrik, _what, pair), do: pair

  defp value(%Wardrik{vault_keys: []}, _ref), do: {:error, :no_keys}

  defp value(wardrik, ref) do
    wardrik
    |> Wardrik.vault()
    |> Wardrik.Vault.value(ref)
  end

  defp sealing(instance) do
    case Wardrik.Instance.fetch!(instance) do
      %Wardrik{vault_keys: []} -> {:error, :no_keys}
      wardrik -> {:ok, wardrik}
    end
  end

  defp named(args) do
    {owner, args} = Keyword.pop!(args, :owner)
    {name, args} = Keyword.pop!(args, :name)
    {owner, name, args}
  end

  defp principal(owner), do: %Principal{id: owner}
end
