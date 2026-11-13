defmodule Wardrik.Workspace.Writes do
  @moduledoc false

  alias Wardrik.Workspace.File
  alias Wardrik.Workspace.Files
  alias Wardrik.Workspace.Mount
  alias Wardrik.Workspace.Reads
  alias Wardrik.Workspace.Spec
  alias Wardrik.Workspace.Tools
  alias WardrikCore.Context

  @max_file_bytes 4 * 1024 * 1024
  @tries 8

  @doc "Writes a whole file over the version read, or appends to its end."
  @spec write_file(Spec.t(), map(), Context.t()) :: {:ok, map()}
  def write_file(spec, args, context) do
    with {:ok, mount, path} <- writable(spec, args[:path]),
         do: writing(spec, mount, path, args, context)
  end

  defp writing(spec, mount, path, %{append: true} = args, context),
    do: retrying(fn -> appended(spec, mount, path, args[:content], context) end)

  defp writing(spec, mount, path, args, context), do: replaced(spec, mount, path, args, context)

  @doc "Replaces text in a file, once or, with `all`, everywhere it appears."
  @spec edit_file(Spec.t(), map(), Context.t()) :: {:ok, map()}
  def edit_file(spec, args, context) do
    with {:ok, mount, path} <- writable(spec, args[:path]),
         do: retrying(fn -> edited(spec, mount, path, args, context) end)
  end

  @doc "Deletes a file. The answer says whether it was there."
  @spec delete_file(Spec.t(), map()) :: {:ok, map()}
  def delete_file(spec, args) do
    with {:ok, mount, path} <- writable(spec, args[:path]),
         do: retrying(fn -> deleted(spec, mount, path) end)
  end

  defp replaced(spec, mount, path, args, context) do
    version = args[:version]

    case written(spec, mount, path, args[:content], version, context) do
      {:error, :conflict} when is_nil(version) ->
        Tools.failed(
          :exists,
          "#{Spec.shown(mount, path)} is there already; pass the version read_file gave to replace it"
        )

      {:error, :conflict} ->
        Tools.failed(
          :conflict,
          "#{Spec.shown(mount, path)} changed since you read it; read it again"
        )

      answer ->
        answer
    end
  end

  defp appended(spec, mount, path, content, context) do
    case Files.read(spec.store, tree: mount.tree, path: path) do
      {:ok, file, version} ->
        kept(spec, mount, path, file, file.content <> content, version, context)

      :none ->
        written(spec, mount, path, content, nil, context)
    end
  end

  defp edited(spec, mount, path, args, context) do
    case Files.read(spec.store, tree: mount.tree, path: path) do
      {:ok, file, version} -> replacing(spec, mount, path, file, version, args, context)
      :none -> Tools.failed(:not_found, "#{Spec.shown(mount, path)} isn't there")
    end
  end

  defp replacing(spec, mount, path, file, version, args, context) do
    case {count(file.content, args[:old]), args[:all]} do
      {0, _all} ->
        Tools.failed(
          :not_found,
          "old isn't in #{Spec.shown(mount, path)}; read it, and copy the text exactly"
        )

      {count, all} when count > 1 and all != true ->
        Tools.failed(
          :ambiguous,
          "old is in #{Spec.shown(mount, path)} #{count} times; give more of it, or pass all"
        )

      {count, _all} ->
        content = String.replace(file.content, args[:old], args[:new], global: args[:all] == true)

        with {:ok, answer} <- kept(spec, mount, path, file, content, version, context),
             do: {:ok, Map.put(answer, :replaced, if(args[:all], do: count, else: 1))}
    end
  end

  defp deleted(spec, mount, path) do
    case Files.read(spec.store, tree: mount.tree, path: path) do
      {:ok, _file, version} ->
        with :ok <- Files.delete(spec.store, tree: mount.tree, path: path, version: version),
             do: {:ok, %{ok: true, deleted: true}}

      :none ->
        {:ok, %{ok: true, deleted: false}}
    end
  end

  defp kept(spec, mount, path, file, content, version, context),
    do: written(spec, mount, path, content, version, context, File.labels(file))

  defp written(spec, mount, path, content, version, context, kept \\ [])

  defp written(_spec, mount, path, content, _version, _context, _kept)
       when byte_size(content) > @max_file_bytes,
       do: Tools.failed(:too_large, "#{Spec.shown(mount, path)} would be over 4 MiB")

  defp written(spec, mount, path, content, version, context, kept) do
    labels =
      (kept ++ Context.labels(context))
      |> Enum.uniq()
      |> Enum.sort()

    file = %File{
      content: content,
      by: context.agent_id,
      at: DateTime.utc_now(),
      labels: labels
    }

    with {:ok, version} <-
           Files.write(spec.store, tree: mount.tree, path: path, file: file, version: version),
         do: {:ok, %{ok: true, path: Spec.shown(mount, path), version: version}}
  end

  defp writable(spec, path) do
    case Reads.resolved(spec, path) do
      {:ok, %Mount{mode: :read} = mount, path} ->
        Tools.failed(:read_only, "#{Spec.shown(mount, path)} is in a tree you may only read")

      resolved ->
        resolved
    end
  end

  defp count(_content, old) when old in [nil, ""], do: 0
  defp count(content, old), do: length(String.split(content, old)) - 1

  defp retrying(change), do: retrying(change, @tries)

  defp retrying(change, 1), do: conflicted(change.())

  defp retrying(change, tries) do
    case change.() do
      {:error, :conflict} -> retrying(change, tries - 1)
      answer -> answer
    end
  end

  defp conflicted({:error, :conflict}),
    do: Tools.failed(:conflict, "others kept changing the file; try again")

  defp conflicted(answer), do: answer
end
