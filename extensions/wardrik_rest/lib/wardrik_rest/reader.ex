defprotocol WardrikRest.Reader do
  @moduledoc """
  Reads an API's description into a `WardrikRest.Spec`.

  `WardrikRest.Discovery` reads Google Discovery documents. Implement it for another format's
  struct to load its APIs the same way:

      defimpl WardrikRest.Reader, for: MyApp.Described do
        def read(%MyApp.Described{} = described), do: {:ok, %WardrikRest.Spec{...}}
      end
  """

  @doc "Returns the spec, or why the description can't be read."
  @spec read(t()) :: {:ok, WardrikRest.Spec.t()} | {:error, String.t()}
  def read(source)
end
