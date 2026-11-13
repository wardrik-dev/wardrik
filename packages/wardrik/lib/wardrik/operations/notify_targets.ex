defmodule Wardrik.Operations.NotifyTargets do
  @moduledoc false

  # The webhooks owners keep for their agents' notices, sent by `Wardrik.Notify.OwnedWebhook`.
  # The deployment's are those Wardrik's `:notify` names. Your resolver gives each agent the
  # targets it routes to; routing to another owner's is `notify_target.use`.

  alias Wardrik.Error
  alias Wardrik.Notify.OwnedWebhook
  alias Wardrik.Operations.Changes
  alias Wardrik.Owned
  alias Wardrik.Scope
  alias WardrikCore.Principal

  @kind "notify_targets"
  @use {"notify_target.use", :notify_target}

  @doc "Lists the owner's targets. The deployment's include those Wardrik's `:notify` names."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    declared = if owner == Owned.deployment(), do: declared(wardrik), else: []
    {:ok, %{"targets" => declared ++ Enum.map(Owned.own(wardrik, @kind, owner), &listed/1)}}
  end

  @doc "Adds a webhook for the owner's agents' notices."
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name} = input) do
    with :ok <- unused(wardrik, owner, name),
         :ok <- reachable(wardrik, input["url"]),
         {:ok, secret} <- secret(wardrik, owner, input["secret"]),
         target = %{owner: owner, name: name, url: input["url"], secret: secret},
         :ok <- Owned.put(wardrik, @kind, target) do
      changed(scope, "notify_target.added", {owner, name, %{"url" => input["url"]}})
      {:ok, listed(target)}
    end
  end

  @doc "Removes one of the owner's own targets. Returns it as it was."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name}) do
    case Owned.get(wardrik, @kind, Owned.reference(owner, name)) do
      nil ->
        not_removed(wardrik, owner, name)

      target ->
        :ok = Owned.delete(wardrik, @kind, owner, name)
        changed(scope, "notify_target.removed", {owner, name, %{}})
        {:ok, listed(target)}
    end
  end

  @doc """
  Returns the targets `principal`'s agents route to, by name, as `Wardrik.Resolved`'s `:notify`
  takes them: its own of each name, else the one another owner lets it use, else the
  deployment's. A name more than one other owner's would do for is left out.
  """
  @spec reached(Wardrik.t(), Principal.t()) :: %{String.t() => Wardrik.Resolved.notify_target()}
  def reached(wardrik, principal) do
    candidates =
      for(target <- Owned.all(wardrik, @kind), do: Map.put(target, :sent, webhook(target))) ++
        for {name, _target} <- wardrik.notify.targets,
            do: %{owner: Owned.deployment(), name: name, sent: name}

    for {name, named} <- Enum.group_by(candidates, & &1.name),
        %{sent: sent} <- [Owned.chosen(wardrik, principal, named, @use)],
        into: %{},
        do: {name, sent}
  end

  @doc "Returns who keeps the resolved target `target`: its owner, or the deployment."
  @spec owner(Wardrik.Resolved.notify_target()) :: String.t()
  def owner({OwnedWebhook, opts}), do: Keyword.fetch!(opts, :owner)
  def owner(_target), do: Owned.deployment()

  defp webhook(%{owner: owner, url: url, secret: nil}),
    do: {OwnedWebhook, [url: url, owner: owner]}

  defp webhook(target),
    do: {OwnedWebhook, [url: target.url, owner: target.owner, secret: target.secret]}

  defp declared(wardrik) do
    for {name, {module, opts}} <- wardrik.notify.targets do
      kind =
        module
        |> Module.split()
        |> List.last()
        |> Macro.underscore()

      target = %{
        "owner" => Owned.deployment(),
        "name" => name,
        "source" => "config",
        "kind" => kind
      }

      if module == Wardrik.Notify.Webhook, do: Map.put(target, "url", opts[:url]), else: target
    end
  end

  defp unused(wardrik, owner, name) do
    if Owned.get(wardrik, @kind, Owned.reference(owner, name)) == nil and
         not declared?(wardrik, owner, name),
       do: :ok,
       else: {:error, Error.new(:conflict, "#{owner} has a notify target #{name} already.")}
  end

  defp not_removed(wardrik, owner, name) do
    if declared?(wardrik, owner, name),
      do:
        {:error, Error.new(:invalid_request, "#{name} is a notify target Wardrik starts with.")},
      else: {:error, Error.new(:not_found, "#{owner} has no notify target #{name}.")}
  end

  defp declared?(wardrik, owner, name),
    do: owner == Owned.deployment() and Map.has_key?(wardrik.notify.targets, name)

  defp reachable(wardrik, url) do
    case wardrik.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The target can't be reached: #{why}.")}
    end
  end

  defp secret(_wardrik, _owner, nil), do: {:ok, nil}

  defp secret(wardrik, owner, %{"name" => name}) do
    if {owner, name, :signing_secret} in Wardrik.Vault.list(Wardrik.vault(wardrik)),
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

  defp changed(scope, type, {owner, name, data}),
    do:
      Changes.record_deployment(scope,
        type: type,
        subject: "notify_targets/" <> name,
        data: %{"notify_target" => Map.put(data, "name", name), "owner" => owner}
      )
end
