defmodule WardrikMCP.Servers.Instance do
  @moduledoc false
  # The servers people add on a `use Wardrik` instance, as WardrikMCP.Servers
  # adds them, signed in to as the instance's WardrikOAuth and vault are. Both
  # are read from its host as each call comes, so they hold whatever order
  # its plugins are listed in.

  alias Wardrik.Host

  @enforce_keys [:store, :instance]
  defstruct [:store, :instance, check: &WardrikMCP.Remote.reachable/1]

  @type t() :: %__MODULE__{store: WardrikStore.t(), instance: module(), check: function()}

  @doc false
  def servers(%__MODULE__{store: store, instance: instance, check: check}) do
    host = Wardrik.Instance.host(instance)
    oauth = Keyword.get_lazy(Host.settings(host, WardrikOAuth), :oauth, &WardrikOAuth.new/0)
    %WardrikMCP.Servers{store: store, oauth: oauth, vault: Host.credentials(host), check: check}
  end
end

defimpl Wardrik.Servers, for: WardrikMCP.Servers.Instance do
  alias WardrikMCP.Servers.Instance

  def list(servers, owner), do: Wardrik.Servers.list(Instance.servers(servers), owner)
  def add(servers, owner, opts), do: Wardrik.Servers.add(Instance.servers(servers), owner, opts)

  def remove(servers, owner, opts),
    do: Wardrik.Servers.remove(Instance.servers(servers), owner, opts)
end
