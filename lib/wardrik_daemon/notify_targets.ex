defmodule WardrikDaemon.NotifyTargets do
  @moduledoc """
  Keeps the webhooks each org or person adds for their agents' notices. `WardrikDaemon.HTTP` serves
  them at `/v1/owners/{owner}/notify_targets`, and `wardrik notify` reaches them there.

  `WardrikDaemon.Resolver` gives each to its owner's agents as a `WardrikDaemon.Webhook`: an org's
  to the org's agents and its people's, a person's to theirs alone. `notify: "ops"` reaches the
  nearest `ops`: the agent owner's, their org's, the deployment's, then `config.yaml`'s.

  A webhook's secret is named, never held: it's read from its owner's vault, sealed for
  `signing_secret`, as each notice is sent. Adding or removing one records `notify_target.added`
  or `notify_target.removed` in the audit.
  """

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Owned
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Servers

  @kind "notify_targets"

  @doc """
  Lists the targets `owner`'s agents route to, nearest first: their own, their org's for a person,
  the deployment's, then those `config.yaml` gives their org. Never a secret, nor a `config.yaml`
  target's options.
  """
  @spec list(Servers.daemon(), String.t()) :: [map()]
  def list(%{store: store, config: config}, owner) do
    added = for target <- Owned.along(store, @kind, owner), do: listed(target)
    Owned.nearest(added ++ configured(config, Owners.org(owner)))
  end

  @doc """
  Returns the targets `owner`'s agents route to by name, as `Wardrik.Resolved`'s `:notify` takes
  them: a webhook added here as a `WardrikDaemon.Webhook`, or the name of one in `config.yaml`.
  """
  @spec reached(Servers.daemon(), String.t()) :: [{String.t(), Wardrik.Resolved.notify_target()}]
  def reached(%{store: store, config: config}, owner) do
    added =
      for target <- Owned.along(store, @kind, owner),
          do: {target.name, {WardrikDaemon.Webhook, webhook(target)}}

    added ++ for(%{"name" => name} <- configured(config, Owners.org(owner)), do: {name, name})
  end

  defp webhook(%{owner: owner, url: url, secret: nil}), do: [url: url, owner: owner]
  defp webhook(target), do: [url: target.url, owner: target.owner, secret: target.secret]

  defp configured(config, org) do
    for {name, {module, opts}} <- Keyword.get(config.notify, :targets, []),
        name = to_string(name),
        Orgs.serves?(config, kind: :notify, name: name, org: org) do
      target = %{
        "owner" => "deployment",
        "name" => name,
        "source" => "config",
        "kind" => kind(module)
      }

      if module == Wardrik.Notify.Webhook, do: Map.put(target, "url", opts[:url]), else: target
    end
  end

  defp kind(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  @doc """
  Adds the webhook `input` describes for `owner`'s agents' notices, as `actor`. Returns it as it's
  kept.

  `input` is the JSON the route takes, already checked against its schema.
  """
  @spec add(Servers.daemon(), {String.t(), map()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def add(%{wardrik: wardrik, store: store} = daemon, {owner, %{"name" => name} = input}, actor) do
    running = Wardrik.Instance.fetch!(wardrik)

    with :ok <- unused(daemon, owner, name),
         :ok <- reachable(running, input["url"]),
         {:ok, secret} <- secret(running, owner, input["secret"]),
         target = %{owner: owner, name: name, url: input["url"], secret: secret},
         {:ok, _vsn} <- WardrikStore.put(store, Owned.path(@kind, owner, name), target) do
      changed(running, "notify_target.added", {owner, name, %{"url" => input["url"]}}, actor)
      {:ok, listed(target)}
    end
  end

  @doc "Removes `owner`'s own target `name`, as `actor`. Returns it as it was."
  @spec remove(Servers.daemon(), {String.t(), String.t()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def remove(%{wardrik: wardrik, store: store} = daemon, {owner, name}, actor) do
    case WardrikStore.get(store, Owned.path(@kind, owner, name)) do
      nil ->
        not_removed(daemon, owner, name)

      target ->
        :ok = WardrikStore.delete(store, Owned.path(@kind, owner, name))

        changed(
          Wardrik.Instance.fetch!(wardrik),
          "notify_target.removed",
          {owner, name, %{}},
          actor
        )

        {:ok, listed(target)}
    end
  end

  defp unused(%{store: store} = daemon, owner, name) do
    if WardrikStore.get(store, Owned.path(@kind, owner, name)) == nil and
         not configured?(daemon, owner, name),
       do: :ok,
       else: {:error, Error.new(:conflict, "#{owner} has a notify target #{name} already.")}
  end

  defp not_removed(daemon, owner, name) do
    if configured?(daemon, owner, name),
      do: {:error, Error.new(:invalid_request, "#{name} is a notify target config.yaml starts.")},
      else: {:error, Error.new(:not_found, "#{owner} has no notify target #{name}.")}
  end

  defp configured?(%{config: config}, "deployment", name),
    do: Enum.any?(Keyword.get(config.notify, :targets, []), &(to_string(elem(&1, 0)) == name))

  defp configured?(_daemon, _owner, _name), do: false

  defp reachable(running, url) do
    case running.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The target can't be reached: #{why}.")}
    end
  end

  defp secret(_running, _owner, nil), do: {:ok, nil}

  defp secret(running, owner, %{"name" => name}) do
    if {owner, name, :signing_secret} in WardrikVault.list(Wardrik.vault(running)),
      do: {:ok, name},
      else:
        {:error,
         Error.new(
           :invalid_request,
           "#{owner} holds no secret #{name} sealed as a signing_secret."
         )}
  end

  defp listed(target) do
    listed = %{
      "owner" => target.owner,
      "name" => target.name,
      "source" => "runtime",
      "kind" => "webhook",
      "url" => target.url
    }

    if target.secret, do: Map.put(listed, "secret", %{"name" => target.secret}), else: listed
  end

  defp changed(running, type, {owner, name, data}, actor) do
    change =
      {type, "notify_targets/" <> name,
       %{"notify_target" => Map.put(data, "name", name), "owner" => owner}}

    :ok = WardrikEvents.record(Wardrik.events(running), change, actor: actor)
  end
end
