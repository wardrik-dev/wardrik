defmodule WardrikCore.Private do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @doc "Puts `value` in the private data under `key`. Use your own module as the key."
      @spec put_private(t(), term(), term()) :: t()
      def put_private(%__MODULE__{} = struct, key, value),
        do: WardrikCore.Private.put(struct, key, value)

      @doc "Returns the private value under `key`, or `default`."
      @spec get_private(t(), term(), term()) :: term()
      def get_private(%__MODULE__{} = struct, key, default \\ nil),
        do: WardrikCore.Private.get(struct, key, default)

      @doc "Updates the private value under `key` with `fun`. Puts `default` if there's none yet."
      @spec update_private(t(), term(), term(), (term() -> term())) :: t()
      def update_private(%__MODULE__{} = struct, key, default, fun),
        do: WardrikCore.Private.update(struct, key, default, fun)
    end
  end

  @type holder :: %{:private => map(), optional(atom()) => term()}

  @spec put(struct, term(), term()) :: struct when struct: holder()
  def put(%{private: private} = struct, key, value),
    do: %{struct | private: Map.put(private, key, value)}

  @spec get(holder(), term(), term()) :: term()
  def get(%{private: private}, key, default), do: Map.get(private, key, default)

  @spec update(struct, term(), term(), (term() -> term())) :: struct
        when struct: holder()
  def update(%{private: private} = struct, key, default, fun),
    do: %{struct | private: Map.update(private, key, default, fun)}
end
