defmodule Wardrik.Catalog do
  @moduledoc """
  The operations a surface can offer without a binding of its own for each:
  every one implements `Wardrik.Catalog.Entry`, so a surface reads its name,
  what it does and its input, builds its request, and runs it as every
  surface does. `Wardrik.Catalog.Tools` offers them to an agent as tools.

  They are listed by what they act on, and by whether they read or change,
  since a surface runs a read with `Wardrik.Query` and a change with
  `Wardrik.Command`, and may hold a change for a person:

  | Operations on | Reads | Changes |
  | --- | --- | --- |
  | an agent | `agent_queries/0` | `agent_commands/0` |

  An operation joins the catalog once it implements `Wardrik.Catalog.Entry`;
  the others are offered by the surfaces that bind them by hand.
  """

  alias Wardrik.Operations.ReadDefinition
  alias Wardrik.Operations.RemoveTrigger
  alias Wardrik.Operations.SetTrigger

  @doc "The operations that read an agent, each a `Wardrik.Query`."
  @spec agent_queries() :: [module()]
  def agent_queries, do: [ReadDefinition]

  @doc "The operations that change an agent, each a `Wardrik.Command`."
  @spec agent_commands() :: [module()]
  def agent_commands, do: [SetTrigger, RemoveTrigger]
end
