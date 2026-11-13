defmodule WardrikRest.Spec do
  @moduledoc """
  What a `WardrikRest.Reader` reads from an API's description: its operations and the ways it
  takes credentials.

    * `:schemes` - each scheme by its name in the description, as `%{"oauth2" => :bearer}`.
    * `:operations` - every operation, as `WardrikRest.Operation`s.
    * `:types` - JSON Schemas by name. Any schema in the spec may refer to one as
      `%{"$ref" => "Campaign"}`, and a type's fields may have descriptions.
  """

  alias WardrikRest.Operation

  @enforce_keys [:title, :operations, :schemes]
  defstruct [:title, :operations, :schemes, types: %{}]

  @typedoc """
  Where a scheme puts its secret: `:bearer` for `Authorization: Bearer ...`, or a named header or
  query parameter.
  """
  @type place() :: :bearer | {:header, String.t()} | {:query, String.t()}

  @type t() :: %__MODULE__{
          title: String.t(),
          operations: [Operation.t()],
          schemes: %{String.t() => place()},
          types: %{String.t() => map()}
        }
end

defmodule WardrikRest.Operation do
  @moduledoc """
  One operation of an API, which becomes one tool.

    * `:name` - unique within the API, as `"properties_runReport"`.
    * `:path` - relative to the API's base URL, with `{name}` and `{+name}` templates.
    * `:security` - alternatives, each the schemes that apply together. `[[]]` needs none.
    * `:encoding` - how its body is sent: `:json`, or `:form` as `application/x-www-form-urlencoded`,
      nested as `card[number]=4242`.
  """

  alias WardrikRest.Parameter

  @enforce_keys [:name, :method, :path, :description, :parameters, :security]
  defstruct [:name, :method, :path, :description, :parameters, :security, encoding: :json]

  @type method() :: :get | :post | :put | :patch | :delete

  @type t() :: %__MODULE__{
          name: String.t(),
          method: method(),
          path: String.t(),
          description: String.t(),
          parameters: [Parameter.t()],
          security: [[String.t()]],
          encoding: :json | :form
        }
end

defmodule WardrikRest.Parameter do
  @moduledoc """
  One argument of an operation: part of its path, its query, a field of its body, the whole
  body, or a header.

    * `in: :body` - one field of an object body, with the operation's other `:body` fields.
    * `in: :payload` - the whole body, for a body that isn't an object of fields.

  `:schema` is a JSON Schema, which may refer to the spec's types. A path parameter with
  `reserved: true` keeps its `/`s, as `properties/123`.
  """

  @enforce_keys [:name, :in, :schema]
  defstruct [:name, :in, :schema, required: false, reserved: false]

  @type t() :: %__MODULE__{
          name: String.t(),
          in: :path | :query | :body | :payload | :header,
          schema: map(),
          required: boolean(),
          reserved: boolean()
        }
end
