defmodule Tars.Tool.Result do
  @moduledoc """
  A consistent envelope for what a tool hands back to the model.

  A call that ran and failed is not the same as a tool that could not run. Most
  of what a tool hits is the first kind: a name that does not exist, a rate
  limit, a search that found nothing. Those are answers, and `error/1` reports
  them as a successful result whose payload says the call failed, so the model
  gets to correct itself or say so plainly.

      def run(params) do
        case Client.search(params) do
          {:ok, result} -> Tars.Tool.Result.ok(result)
          {:error, reason} -> Tars.Tool.Result.error(reason)
        end
      end

  Keep `{:error, reason}` for failures where continuing is meaningless, such as
  a bug in the tool or a malformed argument it cannot interpret.

  The message is the client's own, and it lands in conversation state, so it
  must stay free of credentials.
  """

  @typedoc "A tool result carrying whether the call itself succeeded."
  @type t() :: {:ok, map()}

  @doc """
  Whether a result reports a call that actually did its job.

  A failure reported through `error/1` is a successful *tool*, so a surface
  watching the run needs this to tell a search that found nothing from one that
  never ran.
  """
  @spec ok?(term()) :: boolean()
  def ok?({:ok, %{"ok" => false}}), do: false
  def ok?(_result), do: true

  @doc "Reports a successful call."
  @spec ok(term()) :: t()
  def ok(result), do: {:ok, %{"ok" => true, "result" => result}}

  @doc "Reports a failed call as a result rather than a failed tool."
  @spec error(term()) :: t()
  def error(reason), do: {:ok, %{"ok" => false, "error" => describe(reason)}}

  @doc "The same report, with a code and sentence chosen by the caller."
  @spec error(atom() | String.t(), String.t()) :: t()
  def error(code, message) when is_binary(message),
    do: {:ok, %{"ok" => false, "error" => %{"code" => to_string(code), "message" => message}}}

  # A client that names its own failures gives the model something better than
  # any sentence written around it.
  defp describe(reason) when is_atom(reason),
    do: %{"code" => to_string(reason), "message" => humanize(reason)}

  defp describe(reason) when is_binary(reason),
    do: %{"code" => "request_failed", "message" => reason}

  defp describe({code, detail}) when is_atom(code),
    do: %{"code" => to_string(code), "message" => "#{humanize(code)}: #{inspect(detail)}"}

  defp describe(reason),
    do: %{"code" => "request_failed", "message" => inspect(reason)}

  defp humanize(code), do: code |> to_string() |> String.replace("_", " ")
end
