defmodule Wardrik.Operations.NotifyTargets do
  @moduledoc """
  Operations on the webhooks an org or person adds for their agents' notices.

  An agent routes to the nearest target of a name along `Wardrik.Owners.chain/1`. A target added
  here is always a `Wardrik.Notify.Webhook`, its secret named by reference and read from its
  owner's vault as each notice is sent. See `Wardrik.Notify`.
  """

  alias Wardrik.Error
  alias Wardrik.Notify
  alias Wardrik.NotifyTarget
  alias Wardrik.Operations.Changes
  alias Wardrik.Scope

  @doc "Lists the targets the owner's agents route to: their own, then those from further out."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}),
    do: {:ok, %{"targets" => Enum.map(Notify.targets(wardrik, owner), &answer/1)}}

  @doc "Adds a webhook for the owner's agents' notices. One further out by the same name is overridden."
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(
        %Scope{wardrik: wardrik} = scope,
        %{"owner" => owner, "name" => name, "url" => url} = input
      ) do
    with :ok <- unused(wardrik, owner, name),
         :ok <- reachable(wardrik, url),
         {:ok, secret} <- secret(wardrik, owner, input["secret"]),
         {:ok, _vsn} <-
           WardrikStore.put(store(wardrik), Notify.key(owner, name), [url: url] ++ secret) do
      Changes.record_owned(scope, "notify_target.added", owner, "notify_targets/" <> name, %{
        "notify_target" => %{"name" => name, "url" => url}
      })

      {:ok, answer(own(wardrik, owner, name))}
    end
  end

  @doc "Removes one of the owner's own targets. Returns it as it was."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "target" => name}) do
    case own(wardrik, owner, name) do
      %{source: :runtime} = target ->
        :ok = WardrikStore.delete(store(wardrik), Notify.key(owner, name))

        Changes.record_owned(scope, "notify_target.removed", owner, "notify_targets/" <> name, %{
          "notify_target" => %{"name" => name}
        })

        {:ok, answer(target)}

      %{source: :config} ->
        {:error,
         Error.new(:invalid_request, "#{name} is a notify target the deployment starts with.")}

      nil ->
        {:error, Error.new(:not_found, "#{owner} has no notify target #{name}.")}
    end
  end

  defp unused(wardrik, owner, name) do
    if own(wardrik, owner, name) == nil,
      do: :ok,
      else: {:error, Error.new(:conflict, "#{owner} has a notify target #{name} already.")}
  end

  # The deployment's own include those it starts with.
  defp own(wardrik, owner, name),
    do: Enum.find(Notify.targets(wardrik, owner), &(&1.name == name and &1.owner == owner))

  defp reachable(wardrik, url) do
    case wardrik.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The target can't be reached: #{why}.")}
    end
  end

  defp secret(_wardrik, _owner, nil), do: {:ok, []}

  defp secret(%Wardrik{keys: []}, _owner, _secret),
    do:
      {:error, Error.new(:not_supported, "A target's secret needs Wardrik to keep credentials.")}

  defp secret(wardrik, owner, %{"name" => name}) do
    if name in Wardrik.Sealed.list(wardrik, owner),
      do: {:ok, [secret: {:secret, name}]},
      else: {:error, Error.new(:invalid_request, "#{owner} holds no secret #{name}.")}
  end

  # A target from `:notify` is summed up: its options may hold what only the deployment sees.
  defp answer(target) do
    NotifyTarget.to_json(%NotifyTarget{
      owner: target.owner,
      name: target.name,
      source: target.source,
      kind: kind(target.module),
      url: url(target),
      secret: secret_name(target)
    })
  end

  defp kind(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp url(%{module: Notify.Webhook, opts: opts}), do: opts[:url]
  defp url(_target), do: nil

  defp secret_name(%{source: :runtime, opts: opts}) do
    case opts[:secret] do
      {:secret, name} -> name
      nil -> nil
    end
  end

  defp secret_name(_target), do: nil

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
