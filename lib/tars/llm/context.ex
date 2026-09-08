defmodule Tars.LLM.Context do
  @moduledoc """
  Manipulates ReqLLM.Context{}
  """

  def append_user_message(%ReqLLM.Context{} = context, message) do
    user_message = ReqLLM.Context.user(message)
    ReqLLM.Context.append(context, user_message)
  end
end
