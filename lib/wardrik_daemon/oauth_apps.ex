defmodule WardrikDaemon.OAuthApps do
  @moduledoc """
  Keeps the OAuth apps people sign in with, and says which one each principal uses. It's the
  daemon's `WardrikOAuth.Resolver`. `WardrikDaemon.HTTP` serves them at
  `/v1/owners/{owner}/providers`, and `wardrik provider` reaches them there.

    * `config.yaml`'s `oauth.providers` are the deployment's apps.
    * Orgs and people add their own while the daemon runs. The daemon keeps them in its store.
    * A principal signs in with the nearest app of a name along `WardrikDaemon.Owners.chain/1`:
      their own, their org's, then the deployment's. Another org's app is never used.
    * Each app has a `key` of its own, so a grant is refreshed only by the app that issued it.
      An app added again after it's removed is another app, and its people sign in again.
    * An added app's client secret is named, never kept: it's read from its owner's vault,
      sealed for `client_secret`, each time it's needed.

  An MCP server's own sign-in is an app named by the server's `WardrikMCP` name, as `acme:crm`.
  See `WardrikDaemon.Servers`. Adding or removing an app records `provider.added` or
  `provider.removed` in the audit.
  """

  @behaviour WardrikOAuth.Resolver

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.Owned
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Servers
  alias WardrikOAuth.Provider

  @kind "providers"
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

  @impl WardrikOAuth.Resolver
  def provider(%WardrikOAuth.Resolver.Request{name: name, principal: %Principal{id: id}}, daemon) do
    case nearest(daemon, id, name) do
      nil -> {:error, :not_found}
      app -> resolved(daemon, app)
    end
  end

  @doc """
  Returns the app `owner`'s people sign in with as `name`, or `nil`: their own, their org's, or
  the deployment's.
  """
  @spec nearest(Servers.daemon(), String.t(), String.t()) :: map() | nil
  def nearest(daemon, owner, name),
    do: Enum.find_value(Owners.chain(owner), &app(daemon, &1, name))

  @doc """
  Returns the apps `owner`'s people sign in with, nearest first, the nearest of each name alone.
  An MCP server's own sign-in is among them.
  """
  @spec reached(Servers.daemon(), String.t()) :: [map()]
  def reached(daemon, owner) do
    owner
    |> Owners.chain()
    |> Enum.flat_map(&owned(daemon, &1))
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Lists the apps `owner`'s people sign in with, nearest first: their own, their org's for a
  person, then the deployment's. Never a client secret, nor an MCP server's own sign-in.
  """
  @spec list(Servers.daemon(), String.t()) :: [map()]
  def list(daemon, owner) do
    for app <- reached(daemon, owner), not String.contains?(app.name, ":"), do: listed(app)
  end

  @doc """
  Adds the app `input` describes for `owner`'s people, as `actor`. Returns it as it's kept.

  `input` is the JSON the route takes, already checked against its schema.
  """
  @spec add(Servers.daemon(), {String.t(), map()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def add(daemon, {owner, %{"name" => name} = input}, actor) do
    with :ok <- unused(daemon, owner, name),
         {:ok, app} <- keep(daemon, {owner, input}) do
      changed(daemon, "provider.added", {owner, name}, actor)
      {:ok, listed(app)}
    end
  end

  @doc """
  Keeps the app `input` describes for `owner`, as `add/3` does, with no record in the audit.
  `WardrikDaemon.Servers` keeps a server's own sign-in this way.
  """
  @spec keep(Servers.daemon(), {String.t(), map()}) :: {:ok, map()} | {:error, Error.t()}
  def keep(%{store: store} = daemon, {owner, %{"name" => name} = input}) do
    with :ok <- reachable(daemon, input),
         {:ok, secret} <- client_secret(daemon, owner, input["client_secret"]),
         {:ok, opts} <- options(name, input) do
      app = %{owner: owner, name: name, id: id(), opts: opts, secret: secret}
      {:ok, _vsn} = WardrikStore.put(store, Owned.path(@kind, owner, name), app)
      {:ok, app}
    end
  end

  @doc "Removes `owner`'s own app `name`, as `actor`. Returns it as it was."
  @spec remove(Servers.daemon(), {String.t(), String.t()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def remove(daemon, {owner, name}, actor) do
    case forget(daemon, {owner, name}) do
      {:ok, app} ->
        changed(daemon, "provider.removed", {owner, name}, actor)
        {:ok, listed(app)}

      :error ->
        not_removed(daemon, owner, name)
    end
  end

  @doc """
  Forgets `owner`'s own app `name`, and the client Wardrik registered for it. Returns it as it
  was, or `:error` if `owner` added none of that name.
  """
  @spec forget(Servers.daemon(), {String.t(), String.t()}) :: {:ok, map()} | :error
  def forget(%{wardrik: wardrik, store: store}, {owner, name}) do
    case WardrikStore.get(store, Owned.path(@kind, owner, name)) do
      nil ->
        :error

      app ->
        :ok = WardrikStore.delete(store, Owned.path(@kind, owner, name))
        :ok = forget_client(Wardrik.Instance.fetch!(wardrik), app)
        {:ok, app}
    end
  end

  # Without config.yaml's oauth, no client was ever registered.
  defp forget_client(%Wardrik{oauth: nil}, _app), do: :ok

  defp forget_client(running, app),
    do: WardrikOAuth.forget_client(Wardrik.oauth(running), key(app))

  @doc "Returns the key that names `app`, unique to it."
  @spec key(map()) :: String.t()
  def key(%{owner: owner, name: name, id: id}),
    do: URI.encode_www_form(owner) <> "/" <> name <> "/" <> id

  def key(%{owner: owner, name: name}), do: URI.encode_www_form(owner) <> "/" <> name

  defp app(daemon, "deployment", name),
    do: configured(daemon, name) || added(daemon, "deployment", name)

  defp app(daemon, owner, name), do: added(daemon, owner, name)

  defp added(%{store: store}, owner, name),
    do: WardrikStore.get(store, Owned.path(@kind, owner, name))

  defp owned(daemon, "deployment"),
    do: all_configured(daemon) ++ Owned.own(daemon.store, @kind, "deployment")

  defp owned(daemon, owner), do: Owned.own(daemon.store, @kind, owner)

  defp configured(daemon, name), do: Enum.find(all_configured(daemon), &(&1.name == name))

  defp all_configured(%{config: %{oauth: oauth}}) when is_list(oauth) do
    for {name, opts} <- Keyword.get(oauth, :providers, []) do
      {secret, opts} = Keyword.pop(opts, :client_secret)
      %{owner: "deployment", name: to_string(name), opts: opts, client_secret: secret}
    end
  end

  defp all_configured(_daemon), do: []

  defp resolved(daemon, app) do
    with {:ok, secret} <- read_secret(daemon, app) do
      provider = Provider.new(app.name, app.opts)
      {:ok, %{provider | key: key(app), client_secret: secret}}
    end
  end

  defp read_secret(_daemon, %{client_secret: secret}), do: {:ok, secret}
  defp read_secret(_daemon, %{secret: nil}), do: {:ok, nil}

  defp read_secret(%{wardrik: wardrik}, %{owner: owner, name: name, secret: secret}) do
    vault = wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()

    case WardrikVault.fetch(vault, %Principal{id: owner}, secret, kind: :client_secret) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "#{name}'s client secret #{secret} isn't sealed for #{owner}"}
    end
  end

  defp unused(daemon, owner, name) do
    if app(daemon, owner, name) == nil,
      do: :ok,
      else: {:error, Error.new(:conflict, "#{owner} has an OAuth app #{name} already.")}
  end

  defp not_removed(daemon, owner, name) do
    if owner == "deployment" and configured(daemon, name),
      do: {:error, Error.new(:invalid_request, "#{name} is an OAuth app config.yaml starts.")},
      else: {:error, Error.new(:not_found, "#{owner} has no OAuth app #{name}.")}
  end

  defp reachable(%{wardrik: wardrik}, input) do
    running = Wardrik.Instance.fetch!(wardrik)

    Enum.find_value(@urls, :ok, fn field ->
      with url when is_binary(url) <- input[field],
           {:error, why} <- running.egress.(url) do
        {:error, Error.new(:invalid_request, "The #{field} can't be reached: #{why}.")}
      else
        _reached -> nil
      end
    end)
  end

  defp client_secret(_daemon, _owner, nil), do: {:ok, nil}

  defp client_secret(%{wardrik: wardrik}, owner, %{"name" => name}) do
    vault = wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()

    if {owner, name, :client_secret} in WardrikVault.list(vault),
      do: {:ok, name},
      else:
        {:error,
         Error.new(
           :invalid_request,
           "#{owner} holds no secret #{name} sealed as a client_secret."
         )}
  end

  defp options(name, input) do
    opts = Enum.flat_map(input, &option/1)
    _provider = Provider.new(name, opts)
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

  defp id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  defp listed(app) do
    opts = app.opts

    %{
      "owner" => app.owner,
      "name" => app.name,
      "source" => if(Map.has_key?(app, :id), do: "runtime", else: "config"),
      "scopes" => Keyword.get(opts, :scopes, []),
      "flow" => Atom.to_string(Keyword.get(opts, :flow, :browser)),
      "client_auth" => Atom.to_string(Keyword.get(opts, :client_auth, :post))
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

  defp changed(%{wardrik: wardrik}, type, {owner, name}, actor) do
    change = {type, "providers/" <> name, %{"provider" => %{"name" => name}, "owner" => owner}}
    events = wardrik |> Wardrik.Instance.fetch!() |> Wardrik.events()
    :ok = WardrikEvents.record(events, change, actor: actor)
  end
end
