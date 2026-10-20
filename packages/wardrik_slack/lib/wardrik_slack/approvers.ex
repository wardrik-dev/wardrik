defmodule WardrikSlack.Approvers do
  @moduledoc """
  A workspace's approvers as Slack knows them. Each is named by
  `@handle`, email address or Slack user id, and found as the member a
  message to them is posted to.

  A user id is taken as it is. An email address is looked up with
  `users.lookupByEmail`, which needs the bot token scope `users:read.email`,
  and a handle among the workspace's members with `users.list`, which needs
  `users:read`. A member found is kept for as long as the node runs, so each
  is looked up once.
  """

  @doc """
  Each of `approvers` with the member it names, or `:error` where Slack
  found none. `opts` are the channel's: `:token` and `:req_options`.
  """
  @spec members([String.t()], keyword()) :: [{String.t(), {:ok, String.t()} | :error}]
  def members(approvers, opts), do: Enum.map(approvers, &{&1, member(&1, opts)})

  @doc "Whether `names` include the member `id`. `opts` are as `members/2` takes them."
  @spec include?([String.t()], String.t(), keyword()) :: boolean()
  def include?(names, id, opts), do: Enum.any?(names, &(member(&1, opts) == {:ok, id}))

  @doc ~S"""
  The approvers named in a sentence, `@maria or @jon`, as `config.yaml`
  names them, a user id as Slack shows that member.
  """
  @spec named([String.t()]) :: String.t()
  def named([only]), do: name(only)

  def named(approvers) do
    {most, [last]} = Enum.split(approvers, -1)
    Enum.map_join(most, ", ", &name/1) <> " or " <> name(last)
  end

  defp name(approver), do: if(id?(approver), do: "<@#{approver}>", else: approver)

  defp member(approver, opts) do
    cond do
      id?(approver) -> {:ok, approver}
      found = :persistent_term.get(key(approver, opts), nil) -> {:ok, found}
      true -> approver |> look_up(opts) |> kept(approver, opts)
    end
  end

  defp key(approver, opts), do: {__MODULE__, Keyword.fetch!(opts, :token), approver}

  defp kept({:ok, member} = found, approver, opts) do
    :persistent_term.put(key(approver, opts), member)
    found
  end

  defp kept(:error, _approver, _opts), do: :error

  defp id?(approver), do: Regex.match?(~r/\A[UW][A-Z0-9]+\z/, approver)

  defp look_up("@" <> handle, opts), do: listed(handle, nil, opts)

  defp look_up(email, opts) do
    case slack("users.lookupByEmail", %{email: email}, opts) do
      {:ok, %{"user" => %{"id" => id}}} -> {:ok, id}
      _unknown -> :error
    end
  end

  # The handle is searched for a page of members at a time.
  defp listed(handle, cursor, opts) do
    case slack("users.list", %{limit: 200, cursor: cursor}, opts) do
      {:ok, %{"members" => members} = page} ->
        case Enum.find(members, &(&1["name"] == handle and &1["deleted"] != true)) do
          %{"id" => id} -> {:ok, id}
          nil -> next(handle, get_in(page, ["response_metadata", "next_cursor"]), opts)
        end

      _unlisted ->
        :error
    end
  end

  defp next(_handle, cursor, _opts) when cursor in [nil, ""], do: :error
  defp next(handle, cursor, opts), do: listed(handle, cursor, opts)

  defp slack(method, body, opts),
    do:
      WardrikSlack.read(
        method,
        Keyword.fetch!(opts, :token),
        body,
        Keyword.get(opts, :req_options, [])
      )
end
