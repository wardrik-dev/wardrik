defmodule Wardrik.SignIns do
  @moduledoc """
  Carries on the calls that wait on a sign-in, once the person has signed in.
  """

  alias WardrikCore.Authorization
  alias WardrikCore.Principal

  @doc "Resumes each of `agents` that waits on `principal` signing in to `provider`."
  @spec granted(atom() | String.t(), Principal.t(), atom()) :: :ok
  def granted(provider, %Principal{} = principal, agents) do
    credential = to_string(provider)

    agents
    |> WardrikCore.list()
    |> Enum.map(&WardrikCore.whereis(agents, &1))
    |> Enum.filter(&waits_on?(&1, credential, principal))
    |> Enum.each(&WardrikCore.resume(&1, %{}, %{by: principal}))
  end

  defp waits_on?(nil, _credential, _principal), do: false

  defp waits_on?(agent, credential, principal) do
    case WardrikCore.parked(agent) do
      {:tool_calls, results} -> Enum.any?(results, &signs_in?(&1, credential, principal))
      _reason -> false
    end
  end

  defp signs_in?(
         {_call, {:park, %Authorization{credential: credential, principal: %{id: id}}}},
         credential,
         %Principal{id: id}
       ),
       do: true

  defp signs_in?(_result, _credential, _principal), do: false
end
