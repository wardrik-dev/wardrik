defprotocol WardrikNotify.Rooms do
  @moduledoc """
  What posts a notice in a room a route names, a `WardrikDefinition.Room`
  such as `slack:#updates`. The package that runs a host's channels
  registers one on the host as it attaches, as `WardrikNotify`'s `:rooms`
  setting:

      Wardrik.Host.register(host, :settings, [{WardrikNotify, rooms: rooms}])

  A host that registers none has `WardrikNotify.Rooms.None`, which posts
  nothing and says so.
  """

  @doc """
  Posts `notice` in `room`, in a workspace of the agent's own owner, with
  `:req_options` merged into every HTTP request it makes. Answers
  `{:skip, why}` where there is none to post in, which is logged and not
  tried again.
  """
  @spec post(t(), WardrikDefinition.Room.t(), WardrikNotify.Notice.t(), keyword()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def post(rooms, room, notice, opts)
end
