defmodule Wardrik.Test.S3Bucket do
  @moduledoc """
  An S3 bucket in one ETS table, as a Plug for `Req.Test`: objects, ETags as
  S3 computes them, conditional PUT, GET, DELETE, and ListObjectsV2 in pages
  of two.

      req_options: [plug: {Wardrik.Test.S3Bucket, conditional_delete: true}]

  With `conditional_delete: false` a DELETE ignores `if-match`, as some
  services do, and with `conditional_put: false` a PUT ignores both
  conditions. `drop/1` makes the next request in this process lose its
  answer, `:before` it is applied or `:after`, and `refuse/1` makes every one
  answer an error.
  """

  @behaviour Plug

  import Plug.Conn

  @table __MODULE__
  @page 2

  @doc """
  What `WardrikS3.Store.start_link/1` takes to reach this bucket, with
  `bucket_opts` for the plug and `opts` over the store's own.
  """
  @spec store_opts(keyword(), keyword()) :: keyword()
  def store_opts(bucket_opts \\ [], opts \\ []) do
    Keyword.merge(
      [
        bucket: "wardrik",
        endpoint: "http://s3.test",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        req_options: [plug: {__MODULE__, bucket_opts}, retry_delay: 0]
      ],
      opts
    )
  end

  @doc "Makes every request in this process answer `status`, or answer as the bucket would again, with `nil`."
  @spec refuse(pos_integer() | nil) :: :ok
  def refuse(status) do
    Process.put({__MODULE__, :refuse}, status)
    :ok
  end

  @doc "Empties the bucket."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) == :undefined do
      # Owned by a process of its own, so the bucket outlives the test that
      # made it while what that test started stops.
      {:ok, _owner} =
        Agent.start(fn -> :ets.new(@table, [:named_table, :public, :ordered_set]) end)
    else
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc "Loses the answer to this process's next request, `:before` or `:after` it is applied."
  @spec drop(:before | :after) :: :ok
  def drop(moment) do
    Process.put({__MODULE__, :drop}, moment)
    :ok
  end

  @impl Plug
  def init(opts), do: Map.new(opts)

  @impl Plug
  def call(conn, opts) do
    conn = conn |> fetch_query_params() |> read_whole_body()

    case {Process.get({__MODULE__, :refuse}), Process.delete({__MODULE__, :drop})} do
      {status, _drop} when is_integer(status) -> send_resp(conn, status, error("Refused"))
      {nil, drop} -> dropped(conn, opts, drop)
    end
  end

  defp dropped(conn, opts, drop) do
    case drop do
      :before ->
        Req.Test.transport_error(conn, :timeout)

      :after ->
        _answered = handle(conn, opts)
        Req.Test.transport_error(conn, :timeout)

      nil ->
        handle(conn, opts)
    end
  end

  defp read_whole_body(conn) do
    {:ok, body, conn} = read_body(conn)
    assign(conn, :body, body)
  end

  defp handle(conn, opts) do
    case {conn.method, String.split(conn.request_path, "/", parts: 3)} do
      {"PUT", ["", _bucket]} -> send_resp(conn, 200, "")
      {"GET", ["", _bucket]} -> list(conn)
      {_method, ["", _bucket, key]} -> object(conn, key, opts)
    end
  end

  defp object(%{method: "PUT"} = conn, key, opts) do
    body = conn.assigns.body
    etag = ~s(") <> Base.encode16(:crypto.hash(:md5, body), case: :lower) <> ~s(")

    if not Map.get(opts, :conditional_put, true) or meets?(conn, current(key)) do
      :ets.insert(@table, {key, body, etag})
      conn |> put_resp_header("etag", etag) |> send_resp(200, "")
    else
      precondition_failed(conn)
    end
  end

  defp object(%{method: "GET"} = conn, key, _opts) do
    case current(key) do
      {body, etag} -> conn |> put_resp_header("etag", etag) |> send_resp(200, body)
      nil -> send_resp(conn, 404, error("NoSuchKey"))
    end
  end

  defp object(%{method: "DELETE"} = conn, key, opts) do
    if not Map.get(opts, :conditional_delete, true) or meets?(conn, current(key)) do
      :ets.delete(@table, key)
      send_resp(conn, 204, "")
    else
      precondition_failed(conn)
    end
  end

  defp current(key) do
    case :ets.lookup(@table, key) do
      [{^key, body, etag}] -> {body, etag}
      [] -> nil
    end
  end

  defp meets?(conn, current) do
    case {get_req_header(conn, "if-none-match"), get_req_header(conn, "if-match"), current} do
      {["*"], _match, nil} -> true
      {["*"], _match, _written} -> false
      {[], [etag], {_body, etag}} -> true
      {[], [_etag], _other} -> false
      {[], [], _any} -> true
    end
  end

  defp list(conn) do
    prefix = Map.get(conn.query_params, "prefix", "")
    after_key = Map.get(conn.query_params, "continuation-token")

    matching =
      for {key, body, _etag} <- :ets.tab2list(@table),
          String.starts_with?(key, prefix),
          after_key == nil or key > after_key,
          do: {key, byte_size(body)}

    {page, rest} = Enum.split(matching, @page)

    contents =
      Enum.map(page, fn {key, size} ->
        "<Contents><Key>#{key}</Key><Size>#{size}</Size></Contents>"
      end)

    next =
      case {rest, List.last(page)} do
        {[], _last} ->
          "<IsTruncated>false</IsTruncated>"

        {_more, {key, _size}} ->
          "<IsTruncated>true</IsTruncated><NextContinuationToken>#{key}</NextContinuationToken>"
      end

    send_resp(
      conn,
      200,
      ~s(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>#{contents}#{next}</ListBucketResult>)
    )
  end

  defp precondition_failed(conn), do: send_resp(conn, 412, error("PreconditionFailed"))

  defp error(code), do: "<Error><Code>#{code}</Code></Error>"
end
