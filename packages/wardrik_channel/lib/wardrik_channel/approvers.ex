defprotocol WardrikChannel.Approvers do
  @moduledoc """
  Who in a channel may decide what its agents wait on: the people it
  names, `WardrikChannel.Approvers.Named`, or anyone in the channel,
  `WardrikChannel.Approvers.Anyone`. A host reads them from its own
  settings, as the daemon reads a channel's `approvers` in `config.yaml`:

      channels:
        slack:
          type: slack
          approvers: ["@maria", "ana@example.com"]   # these people
          # approvers: anyone                        # anyone in the channel

  and its `Wardrik.Issuer` asks `decides?/2` whether someone decides, with
  whether names include them, as the channel's adapter says, through
  `WardrikChannel.include?/3`. Naming nobody, a channel's approvers leave
  who decides to the host.
  """

  @doc """
  Whether someone decides, where `include?` answers whether a list of
  names, as the channel names people, includes them.
  """
  @spec decides?(t(), ([String.t()] -> boolean())) :: boolean()
  def decides?(approvers, include?)

  @doc "Whom the channel asks directly what an agent waits on, as it names them."
  @spec asked(t()) :: [String.t()]
  def asked(approvers)

  @doc "What is said of who decides, such as by `wardrik doctor`."
  @spec described(t()) :: String.t()
  def described(approvers)
end
