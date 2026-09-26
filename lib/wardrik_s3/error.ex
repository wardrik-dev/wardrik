defmodule WardrikS3.Error do
  @moduledoc """
  What a bucket answered that `WardrikS3.Store` could not take as an answer:
  a status and the service's error code, or the reason no answer arrived.
  """

  defexception [:message, :status, :code]

  @type t() :: %__MODULE__{
          message: String.t(),
          status: pos_integer() | nil,
          code: String.t() | nil
        }

  @impl true
  def exception(%Req.Response{status: status, body: body}) do
    code = code(body)

    %__MODULE__{
      message: "the bucket answered #{status}#{if code, do: " #{code}"}",
      status: status,
      code: code
    }
  end

  def exception(message: message), do: %__MODULE__{message: message}

  def exception(%{__exception__: true} = reason),
    do: %__MODULE__{message: "the bucket could not be reached: " <> Exception.message(reason)}

  def exception(reason),
    do: %__MODULE__{message: "the bucket could not be reached: #{inspect(reason)}"}

  defp code(body) when is_binary(body) do
    case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
      [_match, code] -> code
      nil -> nil
    end
  end

  defp code(_body), do: nil
end
