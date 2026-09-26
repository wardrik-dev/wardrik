defmodule WardrikHTTP.Definition do
  @moduledoc """
  Where the HTTP API's agent definitions go: the body of
  `PUT /v1/agents/{org}/{user}/{name}`, as
  `priv/protocol/v1/agent_definition.json` describes it, read into the
  `Wardrik.Agent.Spec` it writes.

  `WardrikHTTP.Listener` takes the module as `:definition`. The router checks the
  token's scope, runs the spec `put/2` answers with `Wardrik.Fleet.put/1`, and
  forgets the agent on `DELETE`; the module decides what a definition may say,
  the seams its agent is given, whether it is kept, and who owns a key.

  | Callback | Route | Without it |
  | --- | --- | --- |
  | `put/2` | `PUT /v1/agents/{org}/{user}/{name}` | the listener has no module, and the route answers `501` |
  | `get/1` | `GET /v1/agents/{org}/{user}/{name}/definition` | `501` |
  | `delete/1` | `DELETE /v1/agents/{org}/{user}/{name}` | `501` |

  A daemon's is `WardrikDaemon.Agents`, which reads a definition as it reads an
  agent file, keeps none, and refuses the keys its agent files declare. A
  module that keeps definitions, in `Wardrik.Store` or elsewhere, implements all
  three.
  """

  @doc """
  The spec for the agent under `key`, from the definition's fields, or a
  message saying what does not read. `{:error, :conflict, message}` refuses a
  key the module does not let the API define, and answers `409`.

  The spec is for `key` and no other, and one whose `schedules` is `nil`
  leaves the agent's schedules as they are.
  """
  @callback put(key :: String.t(), definition :: map()) ::
              {:ok, Wardrik.Agent.Spec.t()}
              | {:error, String.t()}
              | {:error, :conflict, String.t()}

  @doc "The definition last put for the agent under `key`, as it was sent."
  @callback get(key :: String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc """
  Told that the agent under `key` is to be forgotten, before it is:
  `:ok` where a definition was kept and is gone, `{:error, :not_found}` where
  none was, and `{:error, :conflict, message}` to refuse, which answers `409`
  and leaves the agent be.
  """
  @callback delete(key :: String.t()) ::
              :ok | {:error, :not_found} | {:error, :conflict, String.t()}

  @optional_callbacks get: 1, delete: 1
end
