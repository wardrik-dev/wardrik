defprotocol WardrikNotify.Destination do
  @moduledoc """
  Where a route sends a notice, as `WardrikDefinition.Route` reads its
  `notify`: a target, by its name among the `:targets`
  `WardrikNotify.Supervisor` was given, or a `WardrikDefinition.Room`,
  posted through the `WardrikNotify.Rooms` the host holds as
  `WardrikNotify`'s `:rooms` setting.
  """

  @doc """
  Sends `notice` to `destination`, given `WardrikNotify.Listener`'s
  options. Answers `{:skip, why}` where there is nothing to send it to,
  which the listener logs and does not try again.
  """
  @spec deliver(t(), WardrikNotify.Notice.t(), keyword()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def deliver(destination, notice, opts)
end

defimpl WardrikNotify.Destination, for: BitString do
  def deliver(name, notice, opts) do
    targets = Keyword.fetch!(opts, :targets)

    with {:ok, {module, target}} <- WardrikNotify.target(targets, name),
         true <- WardrikNotify.tells?(targets, name, Wardrik.AgentAddress.agent(notice.agent).org) do
      target
      |> Keyword.put(:target, name)
      |> Keyword.put_new(:req_options, Keyword.fetch!(opts, :req_options))
      |> then(&module.deliver(notice, &1))
    else
      :error -> {:skip, "which config.yaml does not configure"}
      false -> {:skip, "which tells another org's agents"}
    end
  end
end

defimpl WardrikNotify.Destination, for: WardrikDefinition.Room do
  def deliver(room, notice, opts) do
    opts
    |> Keyword.fetch!(:host)
    |> Wardrik.Host.settings(WardrikNotify)
    |> Keyword.get(:rooms, %WardrikNotify.Rooms.None{})
    |> WardrikNotify.Rooms.post(room, notice, Keyword.take(opts, [:req_options]))
  end
end
