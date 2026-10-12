defprotocol Wardrik.Subject do
  @moduledoc """
  What an operation acts on, and whether a `Wardrik.Grant` lets its holder
  take an action on it.

  A subject a grant does not reach is answered as one that does not exist,
  `:not_found`, so a caller learns nothing of what lies outside its scope; one
  it reaches without the action is `:forbidden`.
  """

  @doc "`:ok` where `grant` lets its holder take `action` on `subject`, or why not."
  @spec authorize(t(), Wardrik.Grant.t(), Wardrik.Grant.action()) ::
          :ok | {:error, Wardrik.Error.t()}
  def authorize(subject, grant, action)
end

defimpl Wardrik.Subject, for: Wardrik.AgentID do
  alias Wardrik.Error
  alias Wardrik.Grant

  @verbs %{
    read: "read",
    message: "send messages to",
    decide: "decide the calls of",
    define: "define",
    serve: "offer tools to"
  }

  def authorize(id, %Grant{} = grant, action) do
    cond do
      not Grant.covers?(grant, id) ->
        {:error, Wardrik.AgentOperation.not_found(id)}

      Grant.allows?(grant, action, id) ->
        :ok

      true ->
        {:error,
         Error.new(:forbidden, "This caller may not #{Map.fetch!(@verbs, action)} #{id}.")}
    end
  end
end

defimpl Wardrik.Subject, for: Wardrik.AgentID.Prefix do
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Grant

  @verbs %{read: "read what is under", define: "change what is under"}

  def authorize(prefix, %Grant{scope: scope, can: can}, action) do
    cond do
      not Prefix.covers?(scope, prefix) ->
        {:error, Error.new(:not_found, "Nothing under #{prefix} is within this caller's reach.")}

      action in can ->
        :ok

      true ->
        {:error,
         Error.new(:forbidden, "This caller may not #{Map.fetch!(@verbs, action)} #{prefix}.")}
    end
  end
end
