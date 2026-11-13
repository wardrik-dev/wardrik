defmodule WardrikDaemon.Test.Screen do
  @moduledoc false

  # An I/O device of 80 columns and 24 rows that keeps what's written to it, for Owl.LiveScreen
  # to draw on in tests. With `:notify`, it sends that process `{:screen, text}` for each write.

  use Agent

  def start_link(opts), do: served(Agent.start_link(fn -> [] end), opts[:notify])

  def written(device) do
    device
    |> Agent.get(&Enum.reverse/1)
    |> IO.iodata_to_binary()
  end

  defp served({:ok, agent}, notify) do
    pid = spawn_link(fn -> serve(agent, notify) end)
    {:ok, pid, agent}
  end

  defp serve(agent, notify) do
    receive do
      {:io_request, from, ref, request} ->
        send(from, {:io_reply, ref, reply(agent, request)})
        if notify, do: send(notify, {:screen, written(agent)})
        serve(agent, notify)
    end
  end

  defp reply(_agent, {:get_geometry, :columns}), do: 80
  defp reply(_agent, {:get_geometry, :rows}), do: 24

  defp reply(agent, {:put_chars, encoding, chars}),
    do: Agent.update(agent, &[:unicode.characters_to_binary(chars, encoding) | &1])

  defp reply(agent, {:put_chars, encoding, module, function, args}),
    do: reply(agent, {:put_chars, encoding, apply(module, function, args)})

  defp reply(agent, {:requests, requests}),
    do: Enum.reduce(requests, :ok, fn request, _reply -> reply(agent, request) end)

  defp reply(_agent, _request), do: {:error, :request}
end
