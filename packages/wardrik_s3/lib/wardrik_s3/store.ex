defmodule WardrikS3.Store do
  @moduledoc """
  A `Wardrik.Store` in an S3 bucket: one object per key, written with S3's
  conditional requests.

      config :wardrik, Wardrik.Store,
        adapter: WardrikS3.Store,
        bucket: "wardrik",
        endpoint: "https://<account>.r2.cloudflarestorage.com",
        region: "auto",
        access_key_id: "...",
        secret_access_key: "..."

  | Option | Default | |
  | --- | --- | --- |
  | `:bucket` | required | |
  | `:endpoint` | required | the service's URL; requests are path-style, `endpoint/bucket/key` |
  | `:access_key_id`, `:secret_access_key` | required | |
  | `:session_token` | none | for temporary credentials |
  | `:region` | `"us-east-1"` | as the service names it; R2 takes `"auto"` |
  | `:prefix` | `"wardrik"` | where in the bucket keys are written, as `<prefix>/<namespace>/<key>` |
  | `:headers` | `[]` | sent with every request, such as `{"x-tigris-consistent", "true"}` on Tigris |
  | `:req_options` | `[]` | given to `Req.new/1` |

  ## Starting it

  `child_spec/1` checks the bucket before anything is kept in it. It writes a
  key twice where nothing is written, and once over a version that is not the
  current one, and starts only where the bucket refuses both. Otherwise it
  fails to start, naming what the bucket let through.

  It then deletes the key over a version that is not the current one. A
  bucket that refuses that deletes a key over its version from then on. One
  that deletes it anyway, as MinIO does, is deleted from by a tombstone: an
  empty object written over the version, which reads as nothing written, is
  written over by a write where nothing is written, and is left out of a
  listing. A tombstone stays in the bucket, since no request could remove it
  only where it is still a tombstone.

  `check/1` runs the same requests, and answers what they found.

  ## Keys, values and versions

  A key is the object `prefix/namespace/key`. Every byte of the namespace and
  the key outside `A-Z`, `a-z`, `0-9`, `-`, `.`, `_` and `/` is written as `~`
  and two hex digits, as is a `.` that begins a segment, so a prefix of a key
  is a prefix of its object, and what is signed is what is sent.

  A value is written with `:erlang.term_to_binary/1`, beside sixteen random
  bytes of its own, and read back with `:safe`, so it names no atom this node
  does not already have. Its version is the object's ETag. No two writes share
  an ETag, even of the same value.

  A write whose answer never arrives is read back before it is answered: it
  succeeded where the object holds its bytes, and conflicted where the object
  holds a version its condition ruled out. A read that fails raises
  `WardrikS3.Error`, since no answer would be true.
  """

  @behaviour Wardrik.Store

  alias WardrikS3.Error

  @config {__MODULE__, :config}
  @required [:bucket, :endpoint, :access_key_id, :secret_access_key]
  @page_size 1000

  @impl Wardrik.Store
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Checks the bucket as the module describes, and keeps `opts` for every call
  after. Nothing runs, so it answers `:ignore`.
  """
  @spec start_link(keyword()) :: :ignore | {:error, term()}
  def start_link(opts) do
    with {:ok, config} <- config(opts),
         {:ok, conditional_delete} <- probe(config) do
      :persistent_term.put(@config, Map.put(config, :conditional_delete, conditional_delete))
      :ignore
    end
  end

  defp config(opts) do
    case Enum.reject(@required, &Keyword.get(opts, &1)) do
      [] ->
        aws =
          [
            access_key_id: opts[:access_key_id],
            secret_access_key: opts[:secret_access_key],
            region: Keyword.get(opts, :region, "us-east-1"),
            service: :s3
          ] ++ if(token = opts[:session_token], do: [token: token], else: [])

        req =
          Req.new(
            [
              base_url: opts[:endpoint],
              aws_sigv4: aws,
              headers: Keyword.get(opts, :headers, []),
              decode_body: false,
              retry: false
            ] ++ Keyword.get(opts, :req_options, [])
          )

        {:ok, %{req: req, bucket: opts[:bucket], prefix: Keyword.get(opts, :prefix, "wardrik")}}

      missing ->
        {:error, {:missing_options, missing}}
    end
  end

  @impl Wardrik.Store
  def check(opts) do
    where = "the bucket #{opts[:bucket]} at #{opts[:endpoint]}"

    with {:ok, config} <- config(opts),
         {:ok, conditional_delete} <- probe(config) do
      {:ok, "#{where} refuses a write whose condition fails, and " <> deletes(conditional_delete)}
    else
      {:error, {:missing_options, missing}} ->
        {:error, "#{where} needs #{Enum.map_join(missing, ", ", &to_string/1)}"}

      {:error, {:unconditional_bucket, what, _response}} ->
        {:error, "#{where}: #{what}, so it cannot hold the store"}

      {:error, %Error{message: message}} ->
        {:error, "#{where}: #{message}"}
    end
  end

  defp deletes(true), do: "deletes over a version"
  defp deletes(false), do: "deletes over any version, so a delete over one writes a tombstone"

  @impl Wardrik.Store
  def quorum(_size), do: 1

  # -- the contract ------------------------------------------------------------

  @impl Wardrik.Store
  def put(ns, key, value, opts) do
    config = config!()
    object = object(config, ns, key)
    nonce = :crypto.strong_rand_bytes(16)
    condition = Keyword.fetch(opts, :if_vsn)

    config
    |> write(object, encode(nonce, value), condition)
    |> confirmed(config, object, nonce, condition)
  end

  # A tombstone counts as nothing written, and is written over by its own version.
  defp write(config, object, body, {:ok, nil}) do
    case put_object(config, object, body, [{"if-none-match", "*"}]) do
      {:error, :conflict} ->
        case read(config, object) do
          {:tombstone, etag} -> put_object(config, object, body, [{"if-match", etag}])
          _written_or_gone -> {:error, :conflict}
        end

      result ->
        result
    end
  end

  defp write(config, object, body, {:ok, vsn}),
    do: put_object(config, object, body, [{"if-match", vsn}])

  defp write(config, object, body, :error), do: put_object(config, object, body, [])

  # A write whose answer never arrived is read back: it landed where the object
  # holds its bytes, and failed where the object still meets its condition.
  defp confirmed({:error, {:unconfirmed, reason}}, config, object, nonce, condition) do
    case read(config, object) do
      {:value, ^nonce, _value, etag} -> {:ok, etag}
      current -> if holds?(current, condition), do: {:error, reason}, else: {:error, :conflict}
    end
  end

  defp confirmed(result, _config, _object, _nonce, _condition), do: result

  defp holds?(_current, :error), do: true
  defp holds?(nil, {:ok, nil}), do: true
  defp holds?({:tombstone, _etag}, {:ok, nil}), do: true
  defp holds?({:value, _nonce, _value, etag}, {:ok, etag}), do: true
  defp holds?(_current, _condition), do: false

  defp put_object(config, object, body, headers) do
    case request(config, :put, object, body: body, headers: headers) do
      {:ok, %{status: 200} = response} -> {:ok, etag(response)}
      {:ok, %{status: status}} when status in [409, 412] -> {:error, :conflict}
      {:ok, response} -> {:error, Error.exception(response)}
      {:error, reason} -> {:error, {:unconfirmed, reason}}
    end
  end

  @impl Wardrik.Store
  def get(ns, key, _opts) do
    case lookup(ns, key) do
      {value, _vsn} -> value
      nil -> nil
    end
  end

  @impl Wardrik.Store
  def lookup(ns, key) do
    config = config!()

    case read(config, object(config, ns, key)) do
      {:value, _nonce, value, etag} -> {value, etag}
      _absent -> nil
    end
  end

  defp read(config, object) do
    case request(config, :get, object, retry: :transient) do
      {:ok, %{status: 200, body: ""} = response} ->
        {:tombstone, etag(response)}

      {:ok, %{status: 200, body: body} = response} ->
        {nonce, value} = :erlang.binary_to_term(body, [:safe])
        {:value, nonce, value, etag(response)}

      {:ok, %{status: 404}} ->
        nil

      {:ok, response} ->
        raise Error.exception(response)

      {:error, reason} ->
        raise Error.exception(reason)
    end
  end

  @impl Wardrik.Store
  def delete(ns, key, opts) do
    config = config!()
    object = object(config, ns, key)

    case Keyword.fetch(opts, :if_vsn) do
      :error ->
        config |> remove(object, []) |> removed(config, object, :error)

      {:ok, vsn} when config.conditional_delete ->
        config |> remove(object, [{"if-match", vsn}]) |> removed(config, object, {:ok, vsn})

      {:ok, vsn} ->
        config
        |> put_object(object, "", [{"if-match", vsn}])
        |> removed(config, object, {:ok, vsn})
    end
  end

  defp remove(config, object, headers) do
    case request(config, :delete, object, headers: headers) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %{status: status}} when status in [409, 412] -> {:error, :conflict}
      {:ok, response} -> {:error, Error.exception(response)}
      {:error, reason} -> {:error, {:unconfirmed, reason}}
    end
  end

  # Removing what is already gone is done, whatever the condition named.
  defp removed({:ok, _tombstone}, _config, _object, _condition), do: :ok
  defp removed(:ok, _config, _object, _condition), do: :ok

  defp removed({:error, :conflict}, config, object, _condition) do
    case read(config, object) do
      {:value, _nonce, _value, _etag} -> {:error, :conflict}
      _absent -> :ok
    end
  end

  defp removed({:error, {:unconfirmed, reason}}, config, object, condition) do
    case read(config, object) do
      {:value, _nonce, _value, _etag} = current ->
        if holds?(current, condition), do: {:error, reason}, else: {:error, :conflict}

      _absent ->
        :ok
    end
  end

  defp removed(error, _config, _object, _condition), do: error

  @impl Wardrik.Store
  def keys(ns, prefix) do
    config = config!()
    root = object(config, ns, "")

    for {object, size} <- list(config, root <> escape(prefix), nil, []),
        size > 0,
        do: object |> String.replace_prefix(root, "") |> unescape()
  end

  # The pages so far are kept last first, and joined once the last is read.
  defp list(config, prefix, token, pages) do
    query =
      [{"list-type", "2"}, {"max-keys", "#{@page_size}"}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(config, :get, nil, query: query, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        {keys, next} = listing(body)
        pages = [keys | pages]

        if next,
          do: list(config, prefix, next, pages),
          else: pages |> Enum.reverse() |> Enum.concat()

      {:ok, response} ->
        raise Error.exception(response)

      {:error, reason} ->
        raise Error.exception(reason)
    end
  end

  defp listing(body) do
    {document, _rest} = body |> String.to_charlist() |> :xmerl_scan.string(quiet: true)

    keys =
      for contents <- :xmerl_xpath.string(~c"//Contents", document) do
        [key] = :xmerl_xpath.string(~c"Key/text()", contents)
        [size] = :xmerl_xpath.string(~c"Size/text()", contents)
        {text(key), size |> text() |> String.to_integer()}
      end

    truncated = Enum.map(:xmerl_xpath.string(~c"//IsTruncated/text()", document), &text/1)

    next =
      case {truncated, :xmerl_xpath.string(~c"//NextContinuationToken/text()", document)} do
        {["true"], [token]} -> text(token)
        _last_page -> nil
      end

    {keys, next}
  end

  defp text(node), do: node |> elem(4) |> List.to_string()

  @impl Wardrik.Store
  def durable_backend(opts) do
    {Wardrik.Store.Durable,
     store: __MODULE__, discovery_interval_ms: Keyword.get(opts, :discovery_interval_ms, 30_000)}
  end

  # -- checking the bucket -----------------------------------------------------

  defp probe(config) do
    object = object(config, :probe, "#{node()}/#{System.unique_integer([:positive])}")
    body = encode(:crypto.strong_rand_bytes(16), :probe)
    stale = ~s("0000000000000000000000000000000f")

    with {:ok, etag} <- probed(config, :put, object, body, [{"if-none-match", "*"}]),
         :ok <-
           refused(
             config,
             :put,
             object,
             body,
             [{"if-none-match", "*"}],
             "wrote a key where one was already written"
           ),
         :ok <-
           refused(
             config,
             :put,
             object,
             body,
             [{"if-match", stale}],
             "wrote over a version that was not the current one"
           ) do
      conditional_delete?(config, object, stale, etag)
    end
  end

  # A bucket that deletes over a version that is not the current one is
  # deleted from by a tombstone written over the version instead.
  defp conditional_delete?(config, object, stale, etag) do
    case request(config, :delete, object, headers: [{"if-match", stale}]) do
      {:ok, %{status: 412}} ->
        _deleted = request(config, :delete, object, headers: [{"if-match", etag}])
        {:ok, true}

      {:ok, %{status: status}} when status in [200, 204] ->
        {:ok, false}

      {:ok, response} ->
        {:error, Error.exception(response)}

      {:error, reason} ->
        {:error, Error.exception(reason)}
    end
  end

  defp probed(config, method, object, body, headers) do
    case request(config, method, object, body: body, headers: headers) do
      {:ok, %{status: 200} = response} -> {:ok, etag(response)}
      {:ok, response} -> {:error, Error.exception(response)}
      {:error, reason} -> {:error, Error.exception(reason)}
    end
  end

  defp refused(config, method, object, body, headers, what) do
    case request(config, method, object, body: body, headers: headers) do
      {:ok, %{status: 412}} ->
        :ok

      {:ok, %{status: status} = response} when status < 300 ->
        _cleaned = request(config, :delete, object, [])
        {:error, {:unconditional_bucket, "the bucket #{what}", Error.exception(response)}}

      {:ok, response} ->
        {:error, Error.exception(response)}

      {:error, reason} ->
        {:error, Error.exception(reason)}
    end
  end

  # -- requests ------------------------------------------------------------------

  defp request(config, method, object, opts) do
    path = if object, do: "/#{config.bucket}/#{object}", else: "/#{config.bucket}"

    url =
      case Keyword.get(opts, :query, []) do
        [] ->
          path

        query ->
          path <> "?" <> Enum.map_join(query, "&", fn {k, v} -> k <> "=" <> encode_query(v) end)
      end

    Req.request(config.req,
      method: method,
      url: url,
      body: opts[:body],
      headers: Keyword.get(opts, :headers, []),
      retry: Keyword.get(opts, :retry, false)
    )
  end

  defp encode_query(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp etag(response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] -> etag
      [] -> nil
    end
  end

  defp encode(nonce, value), do: :erlang.term_to_binary({nonce, value})

  defp config! do
    with nil <- :persistent_term.get(@config, nil) do
      raise Error, message: "WardrikS3.Store was not started"
    end
  end

  # -- keys ----------------------------------------------------------------------

  defp object(config, ns, key), do: "#{config.prefix}/#{escape(to_string(ns))}/" <> escape(key)

  @doc false
  @spec escape(String.t()) :: String.t()
  def escape(key), do: escape(key, true, "")

  # A part of the key is never empty or dot-led in its object's name: a / that
  # would begin one, at the start or after another /, is escaped, since MinIO
  # refuses a name with an empty part, and so is a . that would. Each byte is
  # escaped by what came before it alone, so a prefix's escape is always a
  # prefix of the escape of every key under it.
  defp escape(<<>>, _start, acc), do: acc
  defp escape(<<?/, rest::binary>>, true, acc), do: escape(rest, false, acc <> "~2F")
  defp escape(<<?/, rest::binary>>, false, acc), do: escape(rest, true, acc <> "/")
  defp escape(<<?., rest::binary>>, true, acc), do: escape(rest, false, acc <> "~2E")

  defp escape(<<byte, rest::binary>>, _start, acc)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?-, ?., ?_],
       do: escape(rest, false, acc <> <<byte>>)

  defp escape(<<byte, rest::binary>>, _start, acc),
    do: escape(rest, false, acc <> "~" <> Base.encode16(<<byte>>))

  @doc false
  @spec unescape(String.t()) :: String.t()
  def unescape(object) do
    Regex.replace(~r/~([0-9A-F]{2})/, object, fn _match, hex -> Base.decode16!(hex) end)
  end
end
