defmodule Wardrik.Instance do
  @moduledoc false

  @doc "Returns the running `%Wardrik{}` for `instance`. Raises `ArgumentError` if it isn't started."
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

  @doc "Returns `instance`'s name."
  @spec name(atom() | Wardrik.t()) :: atom()
  def name(%Wardrik{name: name}), do: name
  def name(instance) when is_atom(instance), do: instance

  @doc "Returns the name of the registry that holds `instance` and its named processes."
  @spec registry(atom()) :: atom()
  def registry(instance), do: Module.concat(instance, Registry)

  @doc "Returns the code `use Wardrik` injects. Config is read from `otp_app`."
  @spec using(atom() | nil) :: Macro.t()
  def using(otp_app), do: {:__block__, [], [started(otp_app), scopes()]}

  defp started(otp_app) do
    quote do
      @behaviour Wardrik

      @doc "Starts Wardrik with `opts` over this module's config. See `Wardrik.start_link/1`."
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
      @doc "Returns the scope `principal` acts in. See `Wardrik.as/3`."
      @spec as(WardrikCore.Principal.t() | String.t(), keyword()) :: Wardrik.Scope.t()
      def as(principal, opts \\ []), do: Wardrik.as(__MODULE__, principal, opts)
    end
  end

  defp app_config(nil), do: []

  defp app_config(otp_app),
    do: quote(do: Application.get_env(unquote(otp_app), __MODULE__, []))
end
