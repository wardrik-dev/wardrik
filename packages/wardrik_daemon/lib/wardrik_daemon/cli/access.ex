defmodule WardrikDaemon.CLI.Access do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table
  alias WardrikDaemon.CLI.Terminal

  @owner [org: :string, user: :string]

  @doc "Returns the commands on the vault."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "vault put",
        group: "Vault",
        arguments: "NAME",
        switches: [for: :string] ++ @owner,
        count: 1,
        summary: "seal a secret for the deployment, an --org or a --user",
        details: [
          "At a terminal it asks for the value, not shown as it's typed. Or give it on stdin:",
          "echo \"$VALUE\" | wardrik vault put NAME --for api_key",
          "--for is api_key, client_secret, header or signing_secret. It's read only for that.",
          "${NAME} in config.yaml reads the deployment's secrets."
        ],
        run: &put/3
      },
      %Command{
        name: "vault ls",
        group: "Vault",
        switches: @owner,
        summary: "the names of the secrets held, never their values",
        run: &secrets/3
      },
      %Command{
        name: "vault rm",
        group: "Vault",
        arguments: "NAME",
        switches: @owner,
        count: 1,
        summary: "remove a secret",
        run: &removed/3
      }
    ]
  end

  @purposes ~w(api_key client_secret header signing_secret)

  defp put([name], %{for: purpose} = flags, cx) when purpose in @purposes do
    case value(cx, name) do
      value when is_binary(value) and value != "\n" ->
        seal(cx,
          owner: Context.owner(cx, flags),
          name: name,
          value: String.trim_trailing(value, "\n"),
          purpose: purpose
        )

      _nothing ->
        {:error,
         "Give the value on stdin: echo \"$VALUE\" | #{cx.program} vault put #{name} --for #{purpose}"}
    end
  end

  defp put([name], _flags, cx),
    do:
      {:error,
       "Say what #{name} is for: #{cx.program} vault put #{name} --for api_key, client_secret, header or signing_secret."}

  # Typed at a terminal, unseen, or read from stdin.
  defp value(%{terminal: %{input?: true} = terminal}, name) do
    case Terminal.secret(terminal, "#{name}, not shown as you type: ") do
      nil -> nil
      value -> value <> "\n"
    end
  end

  defp value(_cx, _name), do: IO.gets("")

  @doc """
  Seals `:value` as `:owner`'s secret `:name`, for `:purpose`, and says so.

      Access.seal(cx, owner: "deployment", name: "ZAI_API_KEY", value: key, purpose: "api_key")
  """
  @spec seal(Context.t(),
          owner: String.t(),
          name: String.t(),
          value: String.t(),
          purpose: String.t()
        ) :: :ok | {:error, String.t()}
  def seal(cx, secret) do
    name = Keyword.fetch!(secret, :name)

    input = %{
      "owner" => Keyword.fetch!(secret, :owner),
      "name" => name,
      "value" => Keyword.fetch!(secret, :value),
      "purpose" => Keyword.fetch!(secret, :purpose)
    }

    with {:ok, answer} <- Context.call(cx, "secrets.put", input),
         do: Context.done(cx, answer, "Sealed #{name}.")
  end

  defp secrets([], flags, cx) do
    with {:ok, %{"secrets" => secrets} = answer} <-
           Context.call(cx, "secrets.list", %{"owner" => Context.owner(cx, flags)}) do
      Table.show(cx, answer,
        header: ["SECRET", "PURPOSE"],
        rows: for(secret <- secrets, do: [secret["name"], secret["purpose"]]),
        empty: "No secrets."
      )
    end
  end

  defp removed([name], flags, cx) do
    input = %{"owner" => Context.owner(cx, flags), "name" => name}

    with {:ok, answer} <- Context.call(cx, "secrets.delete", input),
         do: Context.done(cx, answer, "Removed #{name}.")
  end
end
