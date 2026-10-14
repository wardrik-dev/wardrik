defprotocol WardrikDaemon.Approvers do
  @moduledoc """
  Who in a channel may decide what its agents wait on, as its `approvers`
  in `config.yaml` say: the people it names, `WardrikDaemon.Approvers.Named`,
  or anyone in the channel, `WardrikDaemon.Approvers.Anyone`.

      channels:
        slack:
          type: slack
          approvers: ["@maria", "ana@example.com"]   # these people
          # approvers: anyone                        # anyone in the channel

  A channel that sets none names nobody: whoever asked for a turn decides
  what it waits on, and a turn nobody asked for, such as a trigger's, is
  decided from a shell.
  """

  @doc """
  Whether someone decides, where `among` answers whether they are one of a
  list of names, as the channel names people.
  """
  @spec decides?(t(), ([String.t()] -> boolean())) :: boolean()
  def decides?(approvers, among)

  @doc "Whom the channel asks directly what an agent waits on, as it names them."
  @spec asked(t()) :: [String.t()]
  def asked(approvers)

  @doc "What `wardrik doctor` says of who decides."
  @spec described(t()) :: String.t()
  def described(approvers)
end
