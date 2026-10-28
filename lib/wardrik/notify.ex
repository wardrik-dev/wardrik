defmodule Wardrik.Notify do
  @moduledoc """
  Notify tells people when an agent parks, fails or answers while nobody watches. A Wardrik takes
  its targets in `:notify`, each by a name of your own:

      notify: [
        targets: [
          audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: secret},
          ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}
        ]
      ]

  An agent's definition routes its notices with `notify`: a target's name, or a room of one of the
  Wardrik's channels, as `slack:#updates`; a list of them; or `to` and `on`, the kinds of
  `Wardrik.Notice` sent, `parked` and `failed` unless set:

      Wardrik.Agent.define(scope, "acme/triage", model: model, notify: %{to: ["ops"], on: ["finished"]})

  A target with `:orgs` tells only those orgs' agents, and a definition that routes another org's
  agent to it is refused. A conversation of an agent is routed nowhere.

  One process in the cluster follows every agent's log and sends each notice at least once: after
  a restart it carries on from where it was, so tell a repeat by its agent, kind and `at`. A
  delivery that fails is tried again as `:retries` say, 3 more times, each waiting up to 10 seconds
  unless set (see `WardrikCore.Retry`), then logged and dropped.
  """

  alias Wardrik.Error
  alias Wardrik.Notice

  @typedoc "Where an agent's notices go, and which of them."
  @type route() :: %{to: [String.t()], on: [Notice.kind()]}

  @doc "Sends `notice`. `opts` are the target's, with `:wardrik`, the instance, and `:target`, its name."
  @callback deliver(Notice.t(), opts :: keyword()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc "Returns `:notify`'s targets by name, and how a failed delivery is tried again."
  @spec settings(keyword() | nil) :: %{
          targets: %{String.t() => {module(), keyword()}},
          retries: keyword()
        }
  def settings(nil), do: settings([])

  def settings(opts) do
    opts = Keyword.validate!(opts, targets: [], retries: [attempts: 3, max_wait: 10_000])

    %{
      targets: Map.new(opts[:targets], fn {name, target} -> {to_string(name), target} end),
      retries: opts[:retries]
    }
  end

  @doc """
  Returns the route the agent `definition`'s `notify` says, or `nil` for none.

      Wardrik.Notify.route(%{"notify" => "ops"})
      #=> %{to: ["ops"], on: [:parked, :failed]}
  """
  @spec route(map()) :: route() | nil
  def route(%{"notify" => %{"to" => to} = notify}),
    do: %{to: List.wrap(to), on: Enum.map(Map.get(notify, "on", ~w(parked failed)), &kind/1)}

  def route(%{"notify" => to}) when is_binary(to) or is_list(to),
    do: %{to: List.wrap(to), on: [:parked, :failed]}

  def route(_definition), do: nil

  defp kind("parked"), do: :parked
  defp kind("failed"), do: :failed
  defp kind("finished"), do: :finished

  @doc "Returns `:ok` where each place the agent `id`'s `definition` routes to tells it."
  @spec check(Wardrik.t(), String.t(), map()) :: :ok | {:error, Error.t()}
  def check(wardrik, id, definition) do
    case route(definition) do
      nil -> :ok
      %{to: to} -> Enum.find_value(to, :ok, &refused(wardrik, id, &1))
    end
  end

  defp refused(wardrik, id, name) do
    case place(wardrik, name) do
      {:room, _channel, _room} ->
        nil

      {:target, _module, opts} ->
        if tells?(opts, id),
          do: nil,
          else: invalid("The notify target #{name} doesn't tell #{org(id)}'s agents.")

      :error ->
        invalid("There's no notify target #{name} here, nor a channel that posts in it.")
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}

  @doc """
  Sends `notice` to `name`, a target or a channel's room. Returns `{:skip, why}` where there's
  nowhere to send it, which isn't tried again.
  """
  @spec deliver(Wardrik.t(), String.t(), Notice.t()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def deliver(wardrik, name, notice) do
    case place(wardrik, name) do
      {:room, channel, room} ->
        Wardrik.Notify.Room.deliver(notice, wardrik: wardrik.name, channel: channel, room: room)

      {:target, module, opts} ->
        if tells?(opts, notice.agent),
          do:
            module.deliver(
              notice,
              [wardrik: wardrik.name, target: name] ++
                Wardrik.Sealed.resolved(wardrik, "the target #{name}", opts)
            ),
          else: {:skip, "which doesn't tell #{org(notice.agent)}'s agents"}

      :error ->
        {:skip, "which isn't a target or a channel's room here"}
    end
  end

  defp place(wardrik, name) do
    with :error <- Map.fetch(wardrik.notify.targets, name),
         [channel, room] <- String.split(name, ":", parts: 2),
         true <- Map.has_key?(wardrik.channels, channel) and room != "" do
      {:room, channel, room}
    else
      {:ok, {module, opts}} -> {:target, module, opts}
      _neither -> :error
    end
  end

  defp tells?(opts, id) do
    case Keyword.get(opts, :orgs, :all) do
      :all -> true
      orgs -> org(id) in orgs
    end
  end

  defp org(id), do: id |> String.split("/", parts: 2) |> hd()
end
