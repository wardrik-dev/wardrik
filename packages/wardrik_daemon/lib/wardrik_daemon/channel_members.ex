defmodule WardrikDaemon.ChannelMembers do
  @moduledoc """
  Maps chat members to daemon users. It's the daemon's `Wardrik.Chat.Identities`.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          domains: {acme.com: acme}
          members: {U0G9QF9C6: user:acme/@jon}

    * `domains` maps an email domain to an org. A member whose email address is `ana@acme.com`
      acts as `user:acme/@ana`.
    * `members` maps a member ID to a user, and wins over `domains`. A user is a person in an org,
      as `user:acme/@ana`, or `user:admin`.
    * A member acts as their user, with that user's bindings.
    * Anyone else is refused and told to ask an admin.
  """

  @behaviour Wardrik.Chat.Identities

  alias Wardrik.Chat.Identities.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Owners

  @impl Wardrik.Chat.Identities
  def identify(%Request{} = request, opts) do
    case mapped(request, Keyword.fetch!(opts, :members), Keyword.fetch!(opts, :domains)) do
      {:ok, user} ->
        {:ok, %Principal{id: user, attributes: named(request)}}

      :error ->
        {:error,
         "You aren't mapped to a user here. Ask an admin to add you to channels.#{request.channel}.members."}
    end
  end

  defp mapped(%Request{member: member, email: email}, members, domains) do
    with :error <- Map.fetch(members, member), do: by_email(email, domains)
  end

  defp by_email(nil, _domains), do: :error

  defp by_email(email, domains) do
    address = String.downcase(email)

    with [name, domain] <- String.split(address, "@"),
         {:ok, org} <- Map.fetch(domains, domain),
         user = Owners.person(org, name),
         true <- Owners.user?(user) do
      {:ok, user}
    else
      _unmapped -> :error
    end
  end

  defp named(%Request{name: nil}), do: %{}
  defp named(%Request{name: name}), do: %{name: name}

  @doc false
  @spec user(term()) :: {:ok, String.t()} | {:error, String.t()}
  def user("user:" <> id = user) do
    if id == Access.admin() or Owners.user?(id), do: {:ok, id}, else: not_user(user)
  end

  def user(other), do: not_user(other)

  defp not_user(other),
    do: {:error, "is a person in an org, as user:acme/@ana, or user:admin, not #{inspect(other)}"}

  @doc false
  @spec domain(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def domain(domain) do
    if Regex.match?(~r/\A[^@\s]+\.[^@\s]+\z/, domain),
      do: {:ok, String.downcase(domain)},
      else: {:error, "is an email domain, as acme.com, not #{inspect(domain)}"}
  end

  @doc false
  @spec org(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def org(org) do
    if org != "deployment" and Owners.valid?(org) and Owners.person(org) == nil,
      do: {:ok, org},
      else: {:error, "is an org, as acme, not #{inspect(org)}"}
  end
end
