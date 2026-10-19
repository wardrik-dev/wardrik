defmodule Mix.Tasks.Wardrik.Docs do
  @shortdoc "Writes the docs site's reference pages from the code"
  @moduledoc """
  Writes the reference pages of the docs site, under
  `docs/src/content/docs/reference`, from what the code already says: the
  commands `WardrikDaemon.CLI.commands/0` lists, the guides the packages'
  docs carry as extras for `config.yaml`, agent files, policies and the HTTP
  API, and the protocol's JSON Schemas in `packages/wardrik_core/priv/v1`.

      mix wardrik.docs           write them
      mix wardrik.docs --check   fail where one is not what it would write

  A reference page is edited where it comes from, not in the docs site.
  """

  use Mix.Task

  @dir Path.expand("../../../docs/src/content/docs/reference", __DIR__)
  @events "/reference/events/"
  @site "https://docs.wardrik.dev/"
  @edit "https://github.com/wardrik-dev/wardrik/edit/main/packages/"

  # Each guide by the page it is on the site, where a guide links to it.
  @guides %{
    "config" => "config",
    "agent-files" => "agent-files",
    "policies" => "policies",
    "http-api" => "http-api"
  }

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])
    Mix.Task.run("compile")
    pages = pages()

    if opts[:check], do: check(pages), else: write(pages)
  end

  defp pages do
    [
      cli(),
      guide(:wardrik_daemon, "config.md", 2),
      guide(:wardrik_daemon, "agent-files.md", 3),
      guide(:wardrik, "policies.md", 4),
      http(),
      events()
    ]
  end

  defp write(pages) do
    File.mkdir_p!(@dir)
    for {file, text} <- pages, do: File.write!(file, text)
    Mix.shell().info("Wrote #{length(pages)} reference pages in #{Path.relative_to_cwd(@dir)}")
  end

  defp check(pages) do
    case for({file, text} <- pages, File.read(file) != {:ok, text}, do: file) do
      [] -> :ok
      stale -> Mix.raise("#{Enum.join(stale, ", ")}: not what mix wardrik.docs writes; run it")
    end
  end

  # -- pages -------------------------------------------------------------------

  defp page(name, title, order, description, source, body, edit \\ false) do
    front = [
      "---\n",
      "title: #{JSON.encode!(title)}\n",
      "description: #{JSON.encode!(description)}\n",
      "editUrl: #{JSON.encode!(edit)}\n",
      "sidebar:\n  order: #{order}\n",
      "---\n\n",
      "<!-- Written by mix wardrik.docs from #{source}. Edit it there, not here. -->\n\n"
    ]

    {Path.join(@dir, name <> ".md"),
     IO.iodata_to_binary([front, body]) |> String.trim_trailing() |> Kernel.<>("\n")}
  end

  defp guide(package, file, order) do
    {title, body} = read_guide(package, file)
    source = "packages/#{package}/guides/#{file}"
    edit = @edit <> "#{package}/guides/#{file}"
    page(@guides[Path.rootname(file)], title, order, lead(body), source, body, edit)
  end

  # A guide's title, its first line, and the rest with its links made the
  # site's: one to a guide, as `agent-files.md`, or as `e:wardrik_daemon:agent-files.html`
  # in backticks for another package's, to its page, and one to the site to the
  # path alone.
  defp read_guide(package, file) do
    "# " <> text = File.read!(Path.join([package_dir(package), "guides", file]))
    [title, body] = String.split(text, "\n", parts: 2)

    link = ~r/\]\(`?(?:e:[a-z_]+:)?([a-z-]+)\.(?:md|html)(#[^)`]*)?`?\)/

    body =
      Regex.replace(link, String.trim_leading(body), fn _link, guide, anchor ->
        "](/reference/#{Map.fetch!(@guides, guide)}/#{anchor})"
      end)
      |> String.replace("](" <> @site, "](/")

    {title, body}
  end

  # A package's own directory, or a dependency's, by path here or fetched from
  # Hex, so a guide is found wherever its package is.
  defp package_dir(package), do: Map.get(Mix.Project.deps_paths(), package, File.cwd!())

  # The first paragraph, as plain text.
  defp lead(doc) do
    doc
    |> String.split("\n\n", parts: 2)
    |> hd()
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.replace("`", "")
  end

  defp cli do
    commands = WardrikDaemon.CLI.commands()
    code = code(commands)
    intro = WardrikDaemon.CLI.about("~/.config/wardrik")

    groups =
      commands
      |> Enum.chunk_by(& &1.group)
      |> Enum.map_join("\n", fn [%{group: group} | _rest] = chunk ->
        ["## #{group}\n\n", Enum.map_join(chunk, "\n", &command(&1, code))]
      end)

    page(
      "cli",
      "CLI",
      1,
      "Every command wardrik takes, and what each does.",
      "WardrikDaemon.CLI.commands/0",
      [code.(intro), "\n\n", groups]
    )
  end

  defp command(command, code) do
    usage =
      Enum.reject(["wardrik", command.name, command.arguments, command.options], &(&1 == ""))

    details =
      command.details
      |> Enum.chunk_by(&String.starts_with?(&1, "  "))
      |> Enum.map_join("\n\n", &details(&1, code))

    [
      "### wardrik #{command.name}\n\n",
      code.(sentence(command.summary)),
      "\n\n```sh\n#{Enum.join(usage, " ")}\n```\n",
      if(details == "", do: "", else: "\n#{details}\n")
    ]
  end

  # Indented lines in a command's details are examples, and the rest is prose.
  defp details(["  " <> _ | _] = lines, _code),
    do: "```sh\n#{Enum.map_join(lines, "\n", &String.trim_leading/1)}\n```"

  defp details(lines, code), do: code.(Enum.join(lines, " "))

  # Prose written for a terminal, with what is typed or read set as code:
  # commands, flags, environment variables, routes and paths.
  defp code(commands) do
    names =
      commands
      |> Enum.map(& &1.name)
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)

    pattern =
      Regex.compile!(
        "\\b(?:GET|POST|PUT|PATCH|DELETE) /\\S*[\\w}]" <>
          "|\\b(?:wardrik|rik) (?:#{names})(?: [A-Z][A-Z_]*)*\\b" <>
          "|--[a-z][a-z-]*(?: [A-Z][A-Z_]*\\b)?" <>
          "|\\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\\b" <>
          "|~/[\\w./-]*[\\w/]" <>
          "|\\b\\w[\\w.-]*(?:/(?:[@\\w.*-]*[@\\w*-])?)+" <>
          "|\\b[\\w-]+\\.(?:yaml|md|json)\\b"
      )

    &Regex.replace(pattern, &1, "`\\0`")
  end

  defp sentence(text),
    do: String.capitalize(String.first(text)) <> String.slice(text, 1..-1//1) <> "."

  defp http do
    {title, body} = read_guide(:wardrik_http, "http-api.md")
    edit = @edit <> "wardrik_http/guides/http-api.md"

    bodies =
      for {name, schema} <- schemas(), body?(name), do: schema(name, schema, @events)

    page(
      "http-api",
      title,
      5,
      lead(body),
      "packages/wardrik_http/guides/http-api.md and packages/wardrik_core/priv/v1",
      [
        body,
        "\n\n## Bodies\n\nThe JSON the routes take and answer with.\n\n",
        Enum.intersperse(bodies, "\n")
      ],
      edit
    )
  end

  defp events do
    schemas = schemas()
    {"cloudevent", envelope} = List.keyfind(schemas, "cloudevent", 0)
    {"defs", defs} = List.keyfind(schemas, "defs", 0)

    events =
      for {_name, schema} <- schemas, event?(schema), do: schema(schema["title"], schema, "")

    shared =
      for {name, def} <- ordered(defs["$defs"]), do: schema(name, def, "")

    page(
      "events",
      "Events",
      6,
      "The events an agent publishes, as CloudEvents, and the data each carries.",
      "packages/wardrik_core/priv/v1",
      [
        "Every event is a CloudEvent: the envelope below, with the event's own data under `data`.\n\n",
        "## The envelope\n\n",
        description(envelope),
        fields(envelope, ""),
        "\n## Events\n\n",
        Enum.intersperse(events, "\n"),
        "\n## Shared types\n\nThe types events and bodies refer to.\n\n",
        Enum.intersperse(shared, "\n")
      ]
    )
  end

  # -- schemas -----------------------------------------------------------------

  defp schemas do
    WardrikProtocol.dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.basename(&1, ".json"), &1 |> File.read!() |> decode()})
  end

  # A schema with each object's keys kept in order under :keys, since the order
  # a schema lists its fields in is the order to read them in.
  defp decode(json) do
    {schema, :ok, ""} =
      :json.decode(json, :ok, %{
        object_finish: fn pairs, old ->
          {Map.put(Map.new(pairs), :keys, pairs |> Enum.reverse() |> Enum.map(&elem(&1, 0))), old}
        end
      })

    schema
  end

  defp ordered(object), do: for(key <- object.keys, do: {key, object[key]})

  defp event?(schema), do: String.starts_with?(schema["title"] || "", "wardrik.")

  defp body?(name),
    do:
      name not in ["cloudevent", "defs"] and not String.contains?(name, ".") and
        not String.starts_with?(name, "input_")

  defp schema(heading, schema, defs_page) do
    ["### `#{heading}`\n\n", description(schema), fields(schema, defs_page)]
  end

  defp description(%{"description" => description}), do: [description, "\n\n"]
  defp description(_schema), do: []

  defp fields(schema, defs_page) do
    case rows(schema, "", defs_page) do
      [] ->
        "No fields.\n"

      rows ->
        [
          "| Field | Type | Required | Description |\n| --- | --- | --- | --- |\n",
          Enum.map(rows, fn {field, type, required, about} ->
            "| `#{field}` | #{type} | #{if required, do: "yes", else: ""} | #{cell(about)} |\n"
          end)
        ]
    end
  end

  # A row for each field, and for the fields of a field that is an object, by
  # its dotted name.
  defp rows(%{"properties" => properties} = schema, prefix, defs_page) do
    required = Map.get(schema, "required", [])

    Enum.flat_map(ordered(properties), fn {name, field} ->
      path = prefix <> name
      row = {path, type(field, defs_page), name in required, about(field)}
      [row | rows(field, path <> ".", defs_page)]
    end)
  end

  defp rows(_schema, _prefix, _defs_page), do: []

  defp type(%{"$ref" => ref}, defs_page), do: ref(ref, defs_page)
  defp type(%{"const" => value}, _defs_page), do: "`#{JSON.encode!(value)}`"

  defp type(%{"type" => "array", "items" => items}, defs_page),
    do: "array of #{type(items, defs_page)}"

  defp type(%{"type" => types}, _defs_page) when is_list(types), do: Enum.join(types, " or ")
  defp type(%{"type" => type} = field, _defs_page), do: "#{type}#{format(field)}"

  defp type(%{"oneOf" => options}, defs_page),
    do: Enum.map_join(options, " or ", &type(&1, defs_page))

  defp type(%{"anyOf" => options}, defs_page),
    do: Enum.map_join(options, " or ", &type(&1, defs_page))

  defp type(_field, _defs_page), do: "any"

  defp format(%{"format" => format}), do: " (#{format})"
  defp format(_field), do: ""

  # A shared type and the envelope are on the events page, and a body on
  # the HTTP API's.
  defp ref("urn:wardrik:schema:v1:defs#/$defs/" <> name, defs_page),
    do: "[#{name}](#{defs_page}##{name})"

  defp ref("urn:wardrik:schema:v1:cloudevent", _defs_page),
    do: "[event](/reference/events/#the-envelope)"

  defp ref("urn:wardrik:schema:v1:" <> name, _defs_page),
    do: "[#{name}](/reference/http-api/##{name})"

  defp about(field) do
    Enum.join(
      Enum.reject(
        [
          field["description"],
          field["enum"] && "One of #{Enum.map_join(field["enum"], ", ", &"`#{&1}`")}."
        ],
        &is_nil/1
      ),
      " "
    )
  end

  defp cell(text), do: text |> String.replace("|", "\\|") |> String.replace(~r/\s+/, " ")
end
