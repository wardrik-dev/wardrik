if Code.ensure_loaded?(Req) do
  defmodule Wardrik.Store.S3 do
    @moduledoc """
    Keeps keys in an S3 bucket, one object per key, written with S3's conditional requests.

        store =
          Wardrik.Store.S3.new(
            bucket: "wardrik",
            endpoint: "https://<account>.r2.cloudflarestorage.com",
            region: "auto",
            access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
            secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY")
          )

        children = [{Wardrik.Store, store}]

      * Works with AWS S3, R2, Tigris and MinIO: any service that refuses a conditional write
        whose condition fails.
      * Needs no quorum: every node reads and writes the bucket itself.
      * Each read is a request, so it's the slowest adapter. Use it where the data must outlive
        every node.

    ## Starting

    The store checks the bucket before anything is kept in it. It writes a probe key twice where
    nothing is written, and once over a stale version, and starts only where the bucket refuses
    both. Otherwise it fails to start, saying what the bucket let through.

    It then deletes the probe over a stale version. A bucket that refuses deletes over versions
    from then on. One that deletes anyway, as MinIO does, gets a tombstone instead: an empty
    object written over the version. A tombstone reads as nothing, is written over by a write
    where nothing is written, and is left out of listings. Which of the two a bucket does is
    cached on the node.

    ## Values and versions

    An object is JSON, `{"nonce": ..., "value": ...}`: the value beside 16 random bytes in hex.
    Its version is the object's ETag, so no two writes share one.

    A write whose answer never arrives is read back before it's answered: it succeeded where the
    object holds its bytes, and conflicted where the object holds a version its condition ruled
    out. A read that fails raises `Wardrik.Store.S3.Error`.
    """

    @behaviour Wardrik.Store.Adapter

    alias Wardrik.Store.S3.Error

    @required [:bucket, :endpoint, :access_key_id, :secret_access_key]
    @nonce ~s({"nonce":")
    @value ~s(","value":)
    @page_size 1000
    @concurrency 16

    # The request holds the bucket's keys, so a store is shown without it.
    @derive {Inspect, only: [:bucket, :endpoint, :prefix]}
    @enforce_keys [:req, :bucket, :endpoint, :prefix]
    defstruct [:req, :bucket, :endpoint, :prefix]

    @typedoc "The signed request every call starts from, and where keys go."
    @type t() :: %__MODULE__{
            req: Req.Request.t(),
            bucket: String.t(),
            endpoint: String.t(),
            prefix: String.t()
          }

    @doc """
    Builds a store. Starts nothing.

    ## Options

      * `:bucket` - required.
      * `:endpoint` - required. The service's URL. Requests are path-style, `endpoint/bucket/key`.
      * `:access_key_id`, `:secret_access_key` - required.
      * `:session_token` - for temporary credentials.
      * `:region` - as the service names it. `"us-east-1"` unless set; R2 takes `"auto"`.
      * `:prefix` - where in the bucket keys go. `"wardrik"` unless set.
      * `:headers` - sent with every request, such as `{"x-tigris-consistent", "true"}`.
      * `:req_options` - given to `Req.new/1`.

    Raises `ArgumentError` naming the required options it wasn't given.
    """
    @spec new(keyword()) :: Wardrik.Store.t()
    def new(opts) do
      case Enum.reject(@required, &Keyword.get(opts, &1)) do
        [] ->
          Wardrik.Store.new(__MODULE__, %__MODULE__{
            req: request(opts),
            bucket: opts[:bucket],
            endpoint: opts[:endpoint],
            prefix: Keyword.get(opts, :prefix, "wardrik")
          })

        missing ->
          raise ArgumentError,
                "Wardrik.Store.S3 needs #{Enum.map_join(missing, ", ", &inspect/1)}"
      end
    end

    defp request(opts) do
      aws =
        [
          access_key_id: opts[:access_key_id],
          secret_access_key: opts[:secret_access_key],
          region: Keyword.get(opts, :region, "us-east-1"),
          service: :s3
        ] ++ if(token = opts[:session_token], do: [token: token], else: [])

      Req.new(
        [
          base_url: opts[:endpoint],
          aws_sigv4: aws,
          headers: Keyword.get(opts, :headers, []),
          decode_body: false,
          retry: false
        ] ++ Keyword.get(opts, :req_options, [])
      )
    end

    @doc "Checks the bucket as the module describes. Returns `:ignore`, or why it can't hold the store."
    @spec start_link(t()) :: :ignore | {:error, term()}
    def start_link(%__MODULE__{} = store) do
      with {:ok, _conditional_delete} <- deletes_over_version(store), do: :ignore
    end

    # How the bucket deletes is learned from it once per node and store.
    defp deletes_over_version(store) do
      key = {__MODULE__, :conditional_delete, store.endpoint, store.bucket, store.prefix}

      case :persistent_term.get(key, :unknown) do
        :unknown ->
          with {:ok, conditional_delete} <- probe(store) do
            :persistent_term.put(key, conditional_delete)
            {:ok, conditional_delete}
          end

        conditional_delete ->
          {:ok, conditional_delete}
      end
    end

    @impl Wardrik.Store.Adapter
    def child_spec(%__MODULE__{} = store),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [store]}}

    @impl Wardrik.Store.Adapter
    def put(%__MODULE__{} = store, path, value, opts) do
      object = object(store, path)
      nonce = nonce()
      condition = Keyword.fetch(opts, :if_vsn)

      store
      |> write(object, encode(nonce, value), condition)
      |> confirmed(store, object, nonce, condition)
    end

    defp write(store, object, body, {:ok, nil}) do
      case put_object(store, object, body, [{"if-none-match", "*"}]) do
        {:error, :conflict} ->
          case read(store, object) do
            {:tombstone, etag} -> put_object(store, object, body, [{"if-match", etag}])
            _written_or_gone -> {:error, :conflict}
          end

        result ->
          result
      end
    end

    defp write(store, object, body, {:ok, vsn}),
      do: put_object(store, object, body, [{"if-match", vsn}])

    defp write(store, object, body, :error), do: put_object(store, object, body, [])

    defp confirmed({:error, {:unconfirmed, reason}}, store, object, nonce, condition) do
      case read(store, object) do
        {:value, ^nonce, _value, etag} -> {:ok, etag}
        current -> if holds?(current, condition), do: {:error, reason}, else: {:error, :conflict}
      end
    end

    defp confirmed(result, _store, _object, _nonce, _condition), do: result

    defp holds?(_current, :error), do: true
    defp holds?(nil, {:ok, nil}), do: true
    defp holds?({:tombstone, _etag}, {:ok, nil}), do: true
    defp holds?({:value, _nonce, _value, etag}, {:ok, etag}), do: true
    defp holds?(_current, _condition), do: false

    defp put_object(store, object, body, headers) do
      case request(store, :put, object, body: body, headers: headers) do
        {:ok, %{status: 200} = response} -> {:ok, etag(response)}
        {:ok, %{status: status}} when status in [409, 412] -> {:error, :conflict}
        {:ok, response} -> refused_write(response)
        {:error, reason} -> {:error, {:unconfirmed, reason}}
      end
    end

    # MinIO answers a write over a version of a key that isn't there with NoSuchKey.
    defp refused_write(response) do
      case Error.exception(response) do
        %Error{code: "NoSuchKey"} -> {:error, :conflict}
        error -> {:error, error}
      end
    end

    @impl Wardrik.Store.Adapter
    def lookup(%__MODULE__{} = store, path) do
      case read(store, object(store, path)) do
        {:value, _nonce, value, etag} -> {value, etag}
        _absent -> nil
      end
    end

    @impl Wardrik.Store.Adapter
    def lookup_many(%__MODULE__{} = store, paths) do
      paths
      |> Task.async_stream(&{&1, lookup(store, &1)},
        max_concurrency: @concurrency,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, {path, {value, vsn}}} -> [{path, value, vsn}]
        {:ok, {_path, nil}} -> []
      end)
    end

    @impl Wardrik.Store.Adapter
    def entries(%__MODULE__{} = store, prefix), do: lookup_many(store, keys(store, prefix))

    defp read(store, object) do
      case request(store, :get, object, retry: :transient) do
        {:ok, %{status: 200, body: ""} = response} ->
          {:tombstone, etag(response)}

        {:ok, %{status: 200, body: body} = response} ->
          {nonce, value} = decode(body)
          {:value, nonce, value, etag(response)}

        {:ok, %{status: 404}} ->
          nil

        {:ok, response} ->
          raise Error.exception(response)

        {:error, reason} ->
          raise Error.exception(reason)
      end
    end

    @impl Wardrik.Store.Adapter
    def delete(%__MODULE__{} = store, path, opts) do
      object = object(store, path)

      case Keyword.fetch(opts, :if_vsn) do
        :error ->
          store
          |> remove(object, [])
          |> removed(store, object, :error)

        {:ok, vsn} ->
          store
          |> delete_over(object, vsn)
          |> removed(store, object, {:ok, vsn})
      end
    end

    defp delete_over(store, object, vsn) do
      case deletes_over_version(store) do
        {:ok, true} -> remove(store, object, [{"if-match", vsn}])
        {:ok, false} -> put_object(store, object, "", [{"if-match", vsn}])
        {:error, error} -> raise error
      end
    end

    defp remove(store, object, headers) do
      case request(store, :delete, object, headers: headers) do
        {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
        {:ok, %{status: status}} when status in [409, 412] -> {:error, :conflict}
        {:ok, response} -> {:error, Error.exception(response)}
        {:error, reason} -> {:error, {:unconfirmed, reason}}
      end
    end

    # Removing what's already gone is done, whatever the condition named.
    defp removed({:ok, _tombstone}, _store, _object, _condition), do: :ok
    defp removed(:ok, _store, _object, _condition), do: :ok

    defp removed({:error, :conflict}, store, object, _condition) do
      case read(store, object) do
        {:value, _nonce, _value, _etag} -> {:error, :conflict}
        _absent -> :ok
      end
    end

    defp removed({:error, {:unconfirmed, reason}}, store, object, condition) do
      case read(store, object) do
        {:value, _nonce, _value, _etag} = current ->
          if holds?(current, condition), do: {:error, reason}, else: {:error, :conflict}

        _absent ->
          :ok
      end
    end

    defp removed(error, _store, _object, _condition), do: error

    @impl Wardrik.Store.Adapter
    def keys(%__MODULE__{} = store, prefix),
      do: for({path, _etag} <- versions(store, prefix), do: path)

    @impl Wardrik.Store.Adapter
    def versions(%__MODULE__{} = store, prefix) do
      root = store.prefix <> "/"

      for {object, size, etag} <- list(store, object(store, prefix), nil, []),
          size > 0,
          do: {unescape(String.replace_prefix(object, root, "")), etag}
    end

    # Pages are kept last first, and joined once the last is read.
    defp list(store, prefix, token, pages) do
      query =
        [{"list-type", "2"}, {"max-keys", "#{@page_size}"}, {"prefix", prefix}] ++
          if(token, do: [{"continuation-token", token}], else: [])

      case request(store, :get, nil, query: query, retry: :transient) do
        {:ok, %{status: 200, body: body}} ->
          {objects, next} = listing(body)
          pages = [objects | pages]

          if next do
            list(store, prefix, next, pages)
          else
            pages
            |> Enum.reverse()
            |> Enum.concat()
          end

        {:ok, response} ->
          raise Error.exception(response)

        {:error, reason} ->
          raise Error.exception(reason)
      end
    end

    defp listing(body) do
      {document, _rest} =
        body
        |> String.to_charlist()
        |> :xmerl_scan.string(quiet: true)

      objects =
        for contents <- :xmerl_xpath.string(~c"//Contents", document) do
          size = field(contents, ~c"Size/text()")

          {field(contents, ~c"Key/text()"), String.to_integer(size),
           field(contents, ~c"ETag/text()")}
        end

      truncated =
        ~c"//IsTruncated/text()"
        |> :xmerl_xpath.string(document)
        |> Enum.map(&text/1)

      next =
        case {truncated, :xmerl_xpath.string(~c"//NextContinuationToken/text()", document)} do
          {["true"], [token]} -> text(token)
          _last_page -> nil
        end

      {objects, next}
    end

    defp field(node, path) do
      [value] = :xmerl_xpath.string(path, node)
      text(value)
    end

    defp text(node) do
      node
      |> elem(4)
      |> List.to_string()
    end

    defp probe(store) do
      object = object(store, "probe/#{node()}/#{System.unique_integer([:positive])}")
      body = encode(nonce(), ~s("probe"))
      stale = ~s("0000000000000000000000000000000f")

      with {:ok, etag} <- probed(store, object, body, [{"if-none-match", "*"}]),
           :ok <-
             refused(
               store,
               object,
               body,
               [{"if-none-match", "*"}],
               "wrote a key where one was already written"
             ),
           :ok <-
             refused(
               store,
               object,
               body,
               [{"if-match", stale}],
               "wrote over a version that wasn't the current one"
             ) do
        conditional_delete?(store, object, stale, etag)
      end
    end

    # A bucket that deletes over a stale version is deleted from by tombstones instead.
    defp conditional_delete?(store, object, stale, etag) do
      case request(store, :delete, object, headers: [{"if-match", stale}]) do
        {:ok, %{status: 412}} ->
          _deleted = request(store, :delete, object, headers: [{"if-match", etag}])
          {:ok, true}

        {:ok, %{status: status}} when status in [200, 204] ->
          {:ok, false}

        {:ok, response} ->
          {:error, Error.exception(response)}

        {:error, reason} ->
          {:error, Error.exception(reason)}
      end
    end

    defp probed(store, object, body, headers) do
      case request(store, :put, object, body: body, headers: headers) do
        {:ok, %{status: 200} = response} -> {:ok, etag(response)}
        {:ok, response} -> {:error, Error.exception(response)}
        {:error, reason} -> {:error, Error.exception(reason)}
      end
    end

    defp refused(store, object, body, headers, what) do
      case request(store, :put, object, body: body, headers: headers) do
        {:ok, %{status: 412}} ->
          :ok

        {:ok, %{status: status}} when status < 300 ->
          _cleaned = request(store, :delete, object, [])
          {:error, "The bucket #{store.bucket} #{what}, so it can't hold the store."}

        {:ok, response} ->
          {:error, Error.exception(response)}

        {:error, reason} ->
          {:error, Error.exception(reason)}
      end
    end

    defp request(store, method, object, opts) do
      path = if object, do: "/#{store.bucket}/#{object}", else: "/#{store.bucket}"

      url =
        case Keyword.get(opts, :query, []) do
          [] -> path
          query -> path <> "?" <> Enum.map_join(query, "&", fn {k, v} -> k <> "=" <> query(v) end)
        end

      Req.request(store.req,
        method: method,
        url: url,
        body: opts[:body],
        headers: Keyword.get(opts, :headers, []),
        retry: Keyword.get(opts, :retry, false)
      )
    end

    defp query(value), do: URI.encode(value, &URI.char_unreserved?/1)

    defp etag(response) do
      case Req.Response.get_header(response, "etag") do
        [etag | _more] -> etag
        [] -> nil
      end
    end

    defp nonce do
      16
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)
    end

    # The value is spliced in as written, so it reads back byte for byte.
    defp encode(nonce, value), do: @nonce <> nonce <> @value <> value <> "}"

    defp decode(<<@nonce, nonce::binary-size(32), @value, rest::binary>>),
      do: {nonce, binary_part(rest, 0, byte_size(rest) - 1)}

    defp object(store, path), do: store.prefix <> "/" <> escape(path)

    @doc false
    @spec escape(String.t()) :: String.t()
    def escape(key), do: escape(key, true, "")

    # No part of an object's name is empty or starts with a dot, which MinIO refuses. Each byte is
    # escaped by what came before it alone, so a prefix's escape is a prefix of every key's under it.
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
    def unescape(object),
      do: Regex.replace(~r/~([0-9A-F]{2})/, object, fn _match, hex -> Base.decode16!(hex) end)
  end
end
