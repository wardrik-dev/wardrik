defmodule Wardrik.Operations.Snapshot do
  @moduledoc "What operations read of agents: their status from their activity, and their logs."

  alias Wardrik.Error
  alias Wardrik.Scope

  @doc "Returns the agent `id`'s name, the last part of its ID."
  @spec name(String.t()) :: String.t()
  def name(id), do: id |> String.split("/") |> List.last()

  @doc "Returns whether an agent waits for a message, answers one, or waits on a person."
  @spec status(map()) :: String.t()
  def status(%{"doing" => []}), do: "idle"

  def status(%{"doing" => doing}) do
    if Enum.any?(doing, &(&1["type"] == "wardrik.run.interrupted")),
      do: "parked",
      else: "running"
  end

  @doc "Returns the calls an agent's activity says it waits on a person for."
  @spec interrupts(map()) :: [map()]
  def interrupts(%{"doing" => doing}) do
    Enum.flat_map(doing, fn
      %{"type" => "wardrik.run.interrupted", "interrupts" => interrupts} -> interrupts
      _doing -> []
    end)
  end

  @doc "Returns the running agent `id`, or a `not_found` error."
  @spec running(Scope.t(), String.t()) :: {:ok, pid()} | {:error, Error.t()}
  def running(%Scope{wardrik: wardrik}, id) do
    case WardrikCore.whereis(Wardrik.agents(wardrik), id) do
      nil -> {:error, Error.new(:not_found, "There's no agent #{id}.")}
      pid -> {:ok, pid}
    end
  end

  @doc "Returns whether `event` is of one of `types`, or `types` is `nil`."
  @spec typed?(map(), [String.t()] | nil) :: boolean()
  def typed?(_event, nil), do: true
  def typed?(%{"type" => "wardrik.events.dropped"}, _types), do: true
  def typed?(%{"type" => type}, types), do: type in types

  @doc "Reads a page of the logs `patterns` cover."
  @spec page(Scope.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def page(%Scope{wardrik: wardrik}, patterns, opts) do
    wardrik
    |> Wardrik.events()
    |> WardrikEvents.page(patterns, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  @doc "Streams the logs `patterns` cover."
  @spec stream(Scope.t(), [String.t()], keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Scope{wardrik: wardrik}, patterns, opts) do
    wardrik
    |> Wardrik.events()
    |> WardrikEvents.stream(patterns, Enum.reject(opts, &match?({_key, nil}, &1)))
    |> cursor_read()
  end

  defp cursor_read({:ok, read}), do: {:ok, read}

  defp cursor_read({:error, :invalid_cursor}),
    do: {:error, Error.new(:invalid_request, "The cursor doesn't read.")}
end
