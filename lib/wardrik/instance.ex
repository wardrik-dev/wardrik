defmodule Wardrik.Instance do
  @moduledoc false

  @doc "Returns the Wardrik `instance` names, as it started, raising where it hasn't."
  @spec fetch!(atom() | Wardrik.t()) :: Wardrik.t()
  def fetch!(%Wardrik{} = wardrik), do: wardrik

  def fetch!(instance) when is_atom(instance) do
    {:ok, wardrik} = Registry.meta(registry(instance), :wardrik)
    wardrik
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(instance)} isn't started. Add it to your supervision tree, ahead of what uses it.",
              __STACKTRACE__
  end

  @doc "Returns the name a Wardrik is reached by."
  @spec name(atom() | Wardrik.t()) :: atom()
  def name(%Wardrik{name: name}), do: name
  def name(instance) when is_atom(instance), do: instance

  @doc "Returns the registry that holds the Wardrik `instance`, and the processes it names."
  @spec registry(atom()) :: atom()
  def registry(instance), do: Module.concat(instance, Registry)

  @doc "Returns the code `use Wardrik` puts in a module, reading its config from `otp_app`."
  @spec using(atom() | nil) :: Macro.t()
  def using(otp_app), do: {:__block__, [], [started(otp_app), scopes(), secrets()]}

  defp started(otp_app) do
    quote do
      @behaviour Wardrik

      @doc "Starts this Wardrik, with the options its config doesn't give. See `Wardrik.start_link/1`."
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts \\ []) do
        {:ok, config} = init(Keyword.merge(unquote(app_config(otp_app)), opts))
        Wardrik.start_link([name: __MODULE__] ++ Keyword.delete(config, :name))
      end

      @doc false
      def child_spec(opts),
        do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

      @impl Wardrik
      def init(config), do: {:ok, config}

      defoverridable init: 1
    end
  end

  defp scopes do
    quote do
      @doc "Returns the scope `principal` acts in here. See `Wardrik.as/3`."
      @spec as(WardrikCore.Principal.t() | String.t(), term()) :: Wardrik.Scope.t()
      def as(principal, grants \\ []), do: Wardrik.as(__MODULE__, principal, grants)

      @doc "Returns the scope an API token's `secret` acts in here. See `Wardrik.authenticate/2`."
      @spec authenticate(String.t()) :: {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
      def authenticate(secret), do: Wardrik.authenticate(__MODULE__, secret)
    end
  end

  defp secrets do
    quote do
      @doc "Seals a secret of `owner`'s. See `Wardrik.put_secret/5`."
      def put_secret(owner, name, value, opts \\ []),
        do: Wardrik.put_secret(__MODULE__, owner, name, value, opts)

      @doc "Unseals a secret of `owner`'s. See `Wardrik.fetch_secret/3`."
      def fetch_secret(owner, name), do: Wardrik.fetch_secret(__MODULE__, owner, name)

      @doc "Unseals a secret of `owner`'s, with its kind and version. See `Wardrik.lookup_secret/3`."
      def lookup_secret(owner, name), do: Wardrik.lookup_secret(__MODULE__, owner, name)

      @doc "Removes a secret of `owner`'s. See `Wardrik.delete_secret/3`."
      def delete_secret(owner, name), do: Wardrik.delete_secret(__MODULE__, owner, name)

      @doc "Lists the secrets, or `owner`'s. See `Wardrik.list_secrets/2`."
      def list_secrets, do: Wardrik.list_secrets(__MODULE__)
      def list_secrets(owner), do: Wardrik.list_secrets(__MODULE__, owner)
    end
  end

  defp app_config(nil), do: []

  defp app_config(otp_app),
    do: quote(do: Application.get_env(unquote(otp_app), __MODULE__, []))
end
