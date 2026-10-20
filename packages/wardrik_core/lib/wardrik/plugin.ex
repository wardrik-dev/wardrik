defmodule Wardrik.Plugin do
  @moduledoc """
  A package that adds to Wardrik: tools, tool sources, seams, routes or
  children. You list plugins in your instance's config, in order:

      config :my_app, MyApp.Agents,
        store: [repo: MyApp.Repo],
        plugins: [{MyApp.Search, index: "docs"}, {WardrikHTTP, port: 4850}]

  Each entry is a module, or `{module, opts}`. Before Wardrik starts, it
  calls `c:validate/1` where the module has one, then `c:attach/2` with
  the host so far. A plugin listed after another starts after it.

  A plugin is a module with an `attach/2`:

      defmodule MyApp.Search do
        @behaviour Wardrik.Plugin

        @impl true
        def attach(host, opts) do
          host
          |> Wardrik.Host.register(:tools, [{"search", MyApp.Search.Tool}])
          |> Wardrik.Host.child({MyApp.Search.Index, Keyword.take(opts, [:index])})
        end
      end

  `Wardrik.Host` lists what a plugin can add.
  """

  @doc "The host with what the plugin adds to it, read from `opts`."
  @callback attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()

  @doc "`:ok` where `opts` are the plugin's, or why not, checked before anything starts."
  @callback validate(keyword()) :: :ok | {:error, String.t()}

  @optional_callbacks validate: 1
end
