defmodule WardrikDaemon.ChannelMembers do
  @moduledoc """
  Maps chat members to daemon users. It's the daemon's `WardrikChannel.Identities`.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          members: {U024BE7LH: user:acme/@ana, U0G9QF9C6: user:acme/@jon}

    * A mapped member acts as their user, with that user's bindings. A user is a person in an
      org, as `user:acme/@ana`, or `user:admin`.
    * An unmapped member is refused and told to ask an admin.
    * With `unmapped_members: allow`, they act as `user:<channel>:<workspace>/<member>`, as
      `user:slack:T0123/U024BE7LH`.
  """

  @behaviour WardrikChannel.Identities

  alias WardrikChannel.Identities.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Owners

  @impl WardrikChannel.Identities
  def identify(%Request{member: member} = request, opts) do
    case {Map.fetch(Keyword.fetch!(opts, :members), member), Keyword.fetch!(opts, :unmapped)} do
      {{:ok, user}, _unmapped} ->
        {:ok, %Principal{id: user, attributes: named(request)}}

      {:error, :allow} ->
        id = "#{request.channel}:#{request.workspace}/#{member}"
        {:ok, %Principal{id: id, attributes: named(request)}}

      {:error, :refuse} ->
        {:error,
         "You aren't mapped to a user here. Ask an admin to add you to channels.#{request.channel}.members."}
    end
  end

  defp named(%Request{name: nil}), do: %{}
  defp named(%Request{name: name}), do: %{name: name}

  @doc """
  Returns whether `id` is the user of a member no one mapped, as `slack:T0123/U024BE7LH`.
  """
  @spec unmapped?(String.t()) :: boolean()
  def unmapped?(id), do: Regex.match?(~r{\A[a-z][a-z0-9-]*:[^/]+/.+\z}, id)

  @doc false
  def user("user:" <> id = user) do
    if id == Access.admin() or Owners.user?(id), do: {:ok, id}, else: not_user(user)
  end

  def user(other), do: not_user(other)

  defp not_user(other),
    do: {:error, "is a person in an org, as user:acme/@ana, or user:admin, not #{inspect(other)}"}
end
