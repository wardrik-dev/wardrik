defmodule Wardrik.Triggers.Target do
  @moduledoc """
  Connects triggers to your agents. Given to `Wardrik.Triggers` as `:target`, as `{module, opts}`.

      defmodule MyApp.Triggers do
        @behaviour Wardrik.Triggers.Target

        @impl true
        def ask(%Wardrik.Triggers.Target.Ask{agent: id, prompt: prompt}, _opts),
          do: MyApp.Agents.ask(id, prompt)

        @impl true
        def fired(%Wardrik.Triggers.Target.Fired{}, _opts), do: :ok

        @impl true
        def resolve_secret(%Wardrik.Triggers.Target.Secret{agent: id, name: name}, _opts),
          do: MyApp.Secrets.fetch(id, name)
      end

  Each callback takes a request struct, then `opts`.
  """

  alias Wardrik.Triggers.Target.Ask
  alias Wardrik.Triggers.Target.Fired
  alias Wardrik.Triggers.Target.Secret

  @doc """
  Asks the agent the prompt. Returns `:no_agent` if there's no such agent. `{:error, reason}` is
  logged and reported as `:failed`.
  """
  @callback ask(Ask.t(), opts :: term()) :: :asked | :busy | :no_agent | {:error, term()}

  @doc "Called after every run of a trigger, with how it went."
  @callback fired(Fired.t(), opts :: term()) :: :ok

  @doc "Returns the secret held for the agent by the name, or `:error`."
  @callback resolve_secret(Secret.t(), opts :: term()) :: {:ok, String.t()} | :error
end
