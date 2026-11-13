defmodule Wardrik.OAuth.Apps do
  @moduledoc """
  The OAuth apps owners keep, for people to connect accounts with. It's Wardrik's own
  `Wardrik.OAuth.Resolver`, used unless `:oauth` names another.

      Wardrik.Providers.add(scope, "acme",
        name: "linear",
        issuer: "https://linear.app",
        client_id: "...",
        client_secret: %{name: "LINEAR_SECRET"}
      )

    * A sign-in names one app by its reference, `Wardrik.Owned.reference/2` of its owner and
      name, as `"acme:linear"`. Nothing else is looked up.
    * Signing in with another owner's app is `provider.use` on `{:provider, owner}`, as your
      authorizer decides.
    * An app's client secret is read from its owner's vault, sealed for `client_secret`, as each
      sign-in starts.
    * `:oauth`'s `:providers` are the deployment's apps, held by `"deployment"`. They can't be
      removed.
    * An MCP server's own sign-in is an app named `server:` and the server's name. It's kept and
      forgotten with the server, and never listed.
    * The store keeps an app as its owner, name, ID, client secret's name and the fields it was
      added with.
  """

  @behaviour Wardrik.OAuth.Resolver
  @behaviour Wardrik.Owned
  @behaviour Wardrik.Store.Format

  alias Wardrik.Error
  alias Wardrik.OAuth.Provider
  alias Wardrik.Operations.Changes
  alias Wardrik.Owned
  alias WardrikCore.Principal

  @use {"provider.use", :provider}
  @server "server:"
  @urls ~w(issuer resource authorization_endpoint token_endpoint)
  @fields %{
    "issuer" => :issuer,
    "resource" => :resource,
    "authorization_endpoint" => :authorization_endpoint,
    "token_endpoint" => :token_endpoint,
    "client_id" => :client_id,
    "scopes" => :scopes,
    "authorization_params" => :authorization_params
  }
  @choices %{
    "client_auth" => {:client_auth, %{"post" => :post, "basic" => :basic}},
    "flow" => {:flow, %{"browser" => :browser, "device" => :device}}
  }

  @impl Wardrik.Owned
  def kind, do: "providers"

  @impl Wardrik.Store.Format
  def version, do: 1

  @impl Wardrik.Store.Format
  def dump(%{owner: owner, name: name, id: id, secret: secret, opts: opts}) do
    %{
      "owner" => owner,
      "name" => name,
      "id" => id,
      "client_secret" => secret,
      "fields" => Map.new(opts, fn {option, value} -> {Atom.to_string(option), field(value)} end)
    }
  end

  @impl Wardrik.Store.Format
  def load(1, %{"owner" => owner, "name" => name, "id" => id, "fields" => fields} = app) do
    opts = Enum.flat_map(fields, &option/1)
    {:ok, %{owner: owner, name: name, id: id, secret: app["client_secret"], opts: opts}}
  end

  @impl Wardrik.OAuth.Resolver
  def provider(%Wardrik.OAuth.Resolver.Request{name: reference, principal: principal}, name) do
    wardrik = Wardrik.Instance.fetch!(name)

    case find(wardrik, reference) do
      nil ->
        {:error, :not_found}

      app ->
        if Owned.usable?(wardrik, principal, app, @use),
          do: resolved(wardrik, reference, app),
          else: {:error, :not_found}
    end
  end

  @doc "Returns the app at `reference`, the deployment's or one an owner keeps, or `nil`."
  @spec find(Wardrik.t(), String.t()) :: map() | nil
  def find(wardrik, reference) do
    Owned.get(wardrik, __MODULE__, reference) ||
      wardrik
      |> declared()
      |> Enum.find(&(reference(&1) == reference))
  end

  @doc "Returns `app`'s reference, the name a sign-in to it goes by."
  @spec reference(map()) :: String.t()
  def reference(%{owner: owner, name: name}), do: Owned.reference(owner, name)

  @doc """
  Returns the app named `name` that `principal` signs in with: its own, another owner's it may
  use, or the deployment's. `nil` if there's none it may use.
  """
  @spec chosen(Wardrik.t(), Principal.t(), String.t()) :: map() | nil | {:error, [String.t()]}
  def chosen(wardrik, principal, name) do
    candidates =
      Enum.filter(Owned.all(wardrik, __MODULE__) ++ declared(wardrik), &(&1.name == name))

    Owned.chosen(wardrik, principal, candidates, @use)
  end

  @doc """
  Returns the apps `principal` may connect an account with, one per name, as `chosen/3` picks
  them. A server's own sign-in is offered by the server's name.
  """
  @spec offered(Wardrik.t(), Principal.t()) :: [map()]
  def offered(wardrik, principal) do
    for name <- names(wardrik),
        %{} = app <- [chosen(wardrik, principal, name)],
        do: app
  end

  defp names(wardrik),
    do:
      (Owned.all(wardrik, __MODULE__) ++ declared(wardrik))
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()

  @doc "Returns the name a person knows `app` by: its own, or its server's."
  @spec shown(map()) :: String.t()
  def shown(%{name: @server <> server}), do: server
  def shown(%{name: name}), do: name

  @doc "Lists `owner`'s apps. The deployment's include those its options declare."
  @spec list(Wardrik.t(), String.t()) :: [map()]
  def list(wardrik, owner) do
    declared = if owner == Owned.deployment(), do: declared(wardrik), else: []

    for app <- declared ++ Owned.own(wardrik, __MODULE__, owner),
        not String.starts_with?(app.name, @server),
        do: listed(app)
  end

  @doc "Adds the app `input` describes for `owner`, and records it in the audit."
  @spec add(Wardrik.Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(scope, owner, %{"name" => name} = input) do
    with :ok <- unused(scope.wardrik, owner, name),
         {:ok, app} <- keep(scope.wardrik, owner, input) do
      changed(scope, "provider.added", {owner, name})
      {:ok, listed(app)}
    end
  end

  @doc """
  Keeps an app for `owner` as `add/3` does, without an audit record. For an MCP server's own
  sign-in, named `server:` and its name.
  """
  @spec keep(Wardrik.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def keep(wardrik, owner, %{"name" => name} = input) do
    app = %{owner: owner, name: name, id: id()}

    with :ok <- reachable(wardrik, input),
         {:ok, secret} <- client_secret(wardrik, owner, input["client_secret"]),
         {:ok, opts} <- options(app, input),
         app = Map.merge(app, %{opts: opts, secret: secret}),
         :ok <- Owned.put(wardrik, __MODULE__, app) do
      {:ok, app}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{name} wasn't kept: #{inspect(reason)}")}
    end
  end

  @doc "Removes `owner`'s app `name`, and records it in the audit. Returns it as it was."
  @spec remove(Wardrik.Scope.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def remove(scope, owner, name) do
    case forget(scope.wardrik, owner, name) do
      {:ok, app} ->
        changed(scope, "provider.removed", {owner, name})
        {:ok, listed(app)}

      :error ->
        not_removed(scope.wardrik, owner, name)
    end
  end

  @doc "Forgets `owner`'s app `name` and the client registered for it. `:error` if there's none."
  @spec forget(Wardrik.t(), String.t(), String.t()) :: {:ok, map()} | :error
  def forget(wardrik, owner, name) do
    case Owned.get(wardrik, __MODULE__, Owned.reference(owner, name)) do
      nil ->
        :error

      app ->
        :ok = Owned.delete(wardrik, __MODULE__, owner, name)
        :ok = forget_client(wardrik, app)
        {:ok, app}
    end
  end

  # Without `:oauth`, no client was ever registered.
  defp forget_client(%Wardrik{oauth: nil}, _app), do: :ok
  defp forget_client(wardrik, app), do: Wardrik.forget_client(wardrik.name, key(app))

  @doc "Returns the key unique to `app`: an app removed and added again is a new one."
  @spec key(map()) :: String.t()
  def key(%{id: id} = app), do: reference(app) <> "/" <> id
  def key(app), do: reference(app)

  defp declared(%Wardrik{oauth: nil}), do: []

  defp declared(%Wardrik{oauth: oauth}) do
    for {name, opts} <- Keyword.get(oauth, :providers, []) do
      {secret, opts} = Keyword.pop(opts, :client_secret)
      %{owner: Owned.deployment(), name: to_string(name), opts: opts, client_secret: secret}
    end
  end

  defp resolved(wardrik, reference, app) do
    with {:ok, secret} <- read_secret(wardrik, app),
         do: {:ok, Provider.new(reference, [key: key(app), client_secret: secret] ++ app.opts)}
  end

  defp read_secret(_wardrik, %{client_secret: secret}), do: {:ok, secret}
  defp read_secret(_wardrik, %{secret: nil}), do: {:ok, nil}

  defp read_secret(wardrik, %{owner: owner, name: name, secret: secret}) do
    vault = Wardrik.vault(wardrik)

    case Wardrik.Vault.fetch(vault, %Principal{id: owner}, secret, kind: :client_secret) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "#{name}'s client secret #{secret} isn't sealed for #{owner}"}
    end
  end

  defp unused(wardrik, owner, name) do
    if Owned.get(wardrik, __MODULE__, Owned.reference(owner, name)) == nil and
         not declared?(wardrik, owner, name),
       do: :ok,
       else: {:error, Error.new(:conflict, "#{owner} has an OAuth app #{name} already.")}
  end

  defp not_removed(wardrik, owner, name) do
    if declared?(wardrik, owner, name),
      do:
        {:error, Error.new(:invalid_request, "#{name} is an OAuth app the deployment declares.")},
      else: {:error, Error.new(:not_found, "#{owner} has no OAuth app #{name}.")}
  end

  defp declared?(wardrik, owner, name) do
    owner == Owned.deployment() and
      wardrik
      |> declared()
      |> Enum.any?(&(&1.name == name))
  end

  defp reachable(wardrik, input) do
    Enum.find_value(@urls, :ok, fn field ->
      with url when is_binary(url) <- input[field],
           {:error, why} <- wardrik.egress.(url) do
        {:error, Error.new(:invalid_request, "The #{field} can't be reached: #{why}.")}
      else
        _reached -> nil
      end
    end)
  end

  defp client_secret(_wardrik, _owner, nil), do: {:ok, nil}

  defp client_secret(wardrik, owner, %{"name" => name}) do
    vault = Wardrik.vault(wardrik)

    if {owner, name, :client_secret} in Wardrik.Vault.list(vault),
      do: {:ok, name},
      else:
        {:error,
         Error.new(
           :invalid_request,
           "#{owner} holds no secret #{name} sealed as a client_secret."
         )}
  end

  defp options(app, input) do
    opts = Enum.flat_map(input, &option/1)
    _provider = Provider.new(app.name, [key: key(app)] ++ opts)
    {:ok, opts}
  rescue
    error in [ArgumentError, NimbleOptions.ValidationError] ->
      {:error, Error.new(:invalid_request, Exception.message(error))}
  end

  defp option({field, value}) when is_map_key(@fields, field), do: [{@fields[field], value}]

  defp option({field, value}) when is_map_key(@choices, field) do
    {option, values} = @choices[field]
    [{option, Map.fetch!(values, value)}]
  end

  defp option(_other), do: []

  defp field(choice) when is_atom(choice) and not is_boolean(choice) and choice != nil,
    do: Atom.to_string(choice)

  defp field(value), do: value

  defp id do
    bytes = :crypto.strong_rand_bytes(8)
    Base.encode32(bytes, case: :lower, padding: false)
  end

  defp listed(app) do
    opts = app.opts
    flow = Keyword.get(opts, :flow, :browser)
    client_auth = Keyword.get(opts, :client_auth, :post)

    %{
      "owner" => app.owner,
      "name" => app.name,
      "source" => if(Map.has_key?(app, :id), do: "runtime", else: "config"),
      "scopes" => Keyword.get(opts, :scopes, []),
      "flow" => Atom.to_string(flow),
      "client_auth" => Atom.to_string(client_auth)
    }
    |> put_urls(opts)
    |> put("client_id", opts[:client_id])
    |> put("client_secret", app[:secret] && %{"name" => app.secret})
    |> put("authorization_params", params(opts[:authorization_params]))
  end

  defp put_urls(listed, opts),
    do: Enum.reduce(@urls, listed, &put(&2, &1, opts[String.to_existing_atom(&1)]))

  defp params(nil), do: nil
  defp params(params) when params == %{}, do: nil

  defp params(params),
    do: Map.new(params, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp changed(scope, type, {owner, name}),
    do:
      Changes.record_deployment(scope,
        type: type,
        subject: "providers/" <> name,
        data: %{"provider" => %{"name" => name}, "owner" => owner}
      )
end
