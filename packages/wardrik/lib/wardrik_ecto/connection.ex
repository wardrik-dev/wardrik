# Compiled only where the application has :ecto_sql and :postgrex, which are
# optional.
if Code.ensure_loaded?(Ecto.Adapters.SQL) and Code.ensure_loaded?(Postgrex) do
  defmodule WardrikEcto.Connection do
    @moduledoc """
    One connection to Postgres, opened as it starts, for looking at a database
    without a pool: a connection that fails answers why, where a pool would wait
    and try again.
    """

    @behaviour Postgrex.SimpleConnection

    alias Postgrex.SimpleConnection

    @timeout 15_000

    @doc """
    Runs `sql`, a literal query, over one connection made from `config`, as
    `Postgrex.start_link/1` takes it, and closes it. Answers the rows, or why
    there are none, within `timeout` milliseconds.
    """
    @spec query(keyword(), String.t(), pos_integer()) ::
            {:ok, [[String.t() | nil]]} | {:error, term()}
    def query(config, sql, timeout \\ @timeout) do
      # Its own process, unlinked, so a connection that crashes answers why
      # instead of taking the caller with it.
      # credo:disable-for-lines:2 Wardrik.Credo.Check.SupervisedProcesses
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          exit({:answer, run(config, sql, timeout)})
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, {:answer, answer}} -> answer
        {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
      after
        timeout ->
          Process.exit(pid, :kill)
          Process.demonitor(ref, [:flush])
          {:error, "no answer within #{timeout}ms"}
      end
    end

    defp run(config, sql, timeout) do
      with {:ok, conn} <- SimpleConnection.start_link(__MODULE__, [], config) do
        result = SimpleConnection.call(conn, {:query, sql}, timeout)
        :ok = :gen_statem.stop(conn)

        case result do
          [%Postgrex.Result{rows: rows} | _rest] -> {:ok, rows}
          %Postgrex.Error{} = error -> {:error, error}
        end
      end
    end

    @impl Postgrex.SimpleConnection
    def init([]), do: {:ok, nil}

    @impl Postgrex.SimpleConnection
    def notify(_channel, _payload, _state), do: :ok

    @impl Postgrex.SimpleConnection
    def handle_call({:query, sql}, from, _state), do: {:query, sql, from}

    @impl Postgrex.SimpleConnection
    def handle_result(result, from) do
      SimpleConnection.reply(from, result)
      {:noreply, nil}
    end
  end
end
