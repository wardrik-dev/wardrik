defprotocol WardrikChannel.Approvers do
  @moduledoc """
  Who may decide what agents wait on in a workspace: the people named,
  `WardrikChannel.Approvers.Named`, or anyone there,
  `WardrikChannel.Approvers.Anyone`.

      %WardrikChannel.Approvers.Named{names: ["@maria", "ana@example.com"]}
      %WardrikChannel.Approvers.Anyone{}

  Each `WardrikChannel.Installation` carries its own. The daemon reads them
  from a channel's `approvers` in `config.yaml`:

      channels:
        slack:
          type: slack
          approvers: ["@maria", "ana@example.com"]   # or: anyone

  Your `Wardrik.Issuer` asks `decides?/2` whether someone decides, with
  `WardrikChannel.include?/3` matching names to them. Naming nobody leaves
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
