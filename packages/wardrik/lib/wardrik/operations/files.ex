defmodule Wardrik.Operations.Files do
  @moduledoc false

  # Files in an agent's workspace, for people and apps. What they write carries no labels: it's
  # theirs, as the agent's definition is.

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Snapshot
  alias Wardrik.Scope
  alias Wardrik.Workspace.Agents
  alias Wardrik.Workspace.File
  alias Wardrik.Workspace.Files
  alias Wardrik.Workspace.Path

  @max_listed 500
  @max_bytes 4 * 1024 * 1024

  @doc "Lists the agent's files a glob matches, newest first."
  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Scope{wardrik: wardrik}, %{"agent" => id} = input) do
    glob = Map.get(input, "glob", "**")

    with :ok <- Snapshot.known(wardrik, {id, nil}) do
      files =
        wardrik.store
        |> Files.list(Agents.tree(id))
        |> Enum.filter(fn {path, _file, _version} -> Path.match?(glob, path) end)
        |> Enum.sort_by(fn {_path, file, _version} -> file.at end, {:desc, DateTime})
        |> Enum.take(@max_listed)

      {:ok, %{"files" => Enum.map(files, &entry/1)}}
    end
  end

  @doc "Returns one of the agent's files, with its content."
  @spec read(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read(%Scope{wardrik: wardrik}, %{"agent" => id, "path" => path}) do
    with :ok <- Snapshot.known(wardrik, {id, nil}),
         {:ok, path} <- normalized(path),
         {:ok, file, version} <- found(wardrik, id, path) do
      {:ok, %{"file" => entry({path, file, version}), "content" => file.content}}
    end
  end

  @doc "Writes one of the agent's files, over `version` if given, or over whatever is there."
  @spec put(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def put(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "path" => path} = input) do
    file = %File{content: input["content"], by: scope.principal.id, at: DateTime.utc_now()}

    with :ok <- Snapshot.known(wardrik, {id, nil}),
         {:ok, path} <- normalized(path),
         :ok <- sized(file.content),
         {:ok, version} <- written(wardrik, id, path, file, Map.fetch(input, "version")) do
      Changes.record(scope,
        type: "file.written",
        agent: id,
        data: %{"file" => %{"path" => path, "version" => version}}
      )

      {:ok, entry({path, file, version})}
    end
  end

  @doc "Deletes one of the agent's files."
  @spec delete(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def delete(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "path" => path}) do
    with :ok <- Snapshot.known(wardrik, {id, nil}),
         {:ok, path} <- normalized(path),
         {:ok, _file, version} <- found(wardrik, id, path),
         :ok <- deleted(wardrik, id, path, version) do
      Changes.record(scope, type: "file.removed", agent: id, data: %{"file" => %{"path" => path}})
      {:ok, nil}
    end
  end

  defp normalized(path) do
    case Path.normalize(path) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, Error.new(:invalid_request, reason <> ".")}
    end
  end

  defp sized(content) when byte_size(content) <= @max_bytes, do: :ok
  defp sized(_content), do: {:error, Error.new(:invalid_request, "A file is at most 4 MiB.")}

  defp found(wardrik, id, path) do
    case Files.read(wardrik.store, tree: Agents.tree(id), path: path) do
      {:ok, file, version} -> {:ok, file, version}
      :none -> {:error, Error.new(:not_found, "#{id} has no file #{path}.")}
    end
  end

  # Without a version, the write goes over whatever is there now.
  defp written(wardrik, id, path, file, :error),
    do: written(wardrik, id, path, file, {:ok, current(wardrik, id, path)})

  defp written(wardrik, id, path, file, {:ok, version}) do
    tree = Agents.tree(id)

    case Files.write(wardrik.store, tree: tree, path: path, file: file, version: version) do
      {:ok, version} -> {:ok, version}
      {:error, :conflict} -> {:error, changed(id, path)}
    end
  end

  defp current(wardrik, id, path) do
    case Files.read(wardrik.store, tree: Agents.tree(id), path: path) do
      {:ok, _file, version} -> version
      :none -> nil
    end
  end

  defp deleted(wardrik, id, path, version) do
    tree = Agents.tree(id)

    case Files.delete(wardrik.store, tree: tree, path: path, version: version) do
      :ok -> :ok
      {:error, :conflict} -> {:error, changed(id, path)}
    end
  end

  defp changed(id, path),
    do: Error.new(:conflict, "#{id}'s #{path} changed since it was read. Read it again.")

  defp entry({path, file, version}) do
    %{
      "path" => path,
      "version" => version,
      "bytes" => byte_size(file.content),
      "by" => file.by,
      "at" => DateTime.to_iso8601(file.at),
      "labels" => File.labels(file)
    }
  end
end
