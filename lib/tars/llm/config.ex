defmodule Tars.LLM.Config do
  @moduledoc """
  Config for LLM calling
  """

  defstruct model_spec: {:zai_coding_plan, model: "glm-5-turbo"},
            callback_mod: Tars.LLM.DefaultCallbacks

  @type t :: %__MODULE__{
          model_spec: {atom(), keyword()},
          callback_mod: module()
        }

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
