defprotocol WardrikStore.Adapter do
  @moduledoc """
  What a store does, implemented by each adapter's struct. Callers go
  through `WardrikStore`, which hands the store to these functions; see it
  for what each answers.
  """

  @doc "The child that runs the store."
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(store)

  @doc """
  Looks at the store without starting it, and answers what it found, naming
  the store: that it is there and keeps the contract, or why not.
  """
  @spec check(t()) :: {:ok, String.t()} | {:error, String.t()}
  def check(store)

  @doc "How many nodes of a cluster of `size` must be connected. See `WardrikStore.quorum/2`."
  @spec quorum(t(), pos_integer()) :: pos_integer()
  def quorum(store, size)

  @doc "The `DurableServer` backend agents are written through."
  @spec durable_backend(t()) :: {module(), keyword()}
  def durable_backend(store)

  @doc "Writes a value, conditionally where `opts` say so."
  @spec put(t(), WardrikStore.ns(), WardrikStore.key(), term(), WardrikStore.put_opts()) ::
          {:ok, WardrikStore.vsn() | nil} | {:error, :conflict | term()}
  def put(store, ns, key, value, opts)

  @doc "The value under a key, or `nil`."
  @spec get(t(), WardrikStore.ns(), WardrikStore.key(), WardrikStore.get_opts()) ::
          term() | nil
  def get(store, ns, key, opts)

  @doc "The value under a key with its version, or `nil`."
  @spec lookup(t(), WardrikStore.ns(), WardrikStore.key()) :: {term(), WardrikStore.vsn()} | nil
  def lookup(store, ns, key)

  @doc "Removes a key. Removing one that is not there is `:ok`."
  @spec delete(t(), WardrikStore.ns(), WardrikStore.key(), WardrikStore.delete_opts()) ::
          :ok | {:error, :conflict | term()}
  def delete(store, ns, key, opts)

  @doc "Every key in a namespace starting with `prefix`."
  @spec keys(t(), WardrikStore.ns(), String.t()) :: [WardrikStore.key()]
  def keys(store, ns, prefix)
end
