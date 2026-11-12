if Code.ensure_loaded?(Req) do
  defmodule WardrikStore.S3.Error do
    @moduledoc """
    What a bucket answered that `WardrikStore.S3` can't take as an answer: a status and the
    service's error code, or why no answer arrived.
    """

    defexception [:message, :status, :code]

    @type t() :: %__MODULE__{
            message: String.t(),
            status: pos_integer() | nil,
            code: String.t() | nil
          }

    @impl Exception
    def exception(%Req.Response{status: status, body: body}) do
      code = code(body)

      %__MODULE__{
        message: "The bucket answered #{status}#{if code, do: " #{code}"}.",
        status: status,
        code: code
      }
    end

    def exception(%{__exception__: true} = reason),
      do: %__MODULE__{message: "Couldn't reach the bucket: " <> Exception.message(reason)}

    def exception(reason),
      do: %__MODULE__{message: "Couldn't reach the bucket: #{inspect(reason)}"}

    defp code(body) when is_binary(body) do
      case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
        [_match, code] -> code
        nil -> nil
      end
    end

    defp code(_body), do: nil
  end
end
