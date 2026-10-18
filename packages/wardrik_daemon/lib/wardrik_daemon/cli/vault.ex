defmodule WardrikDaemon.CLI.Vault do
  @moduledoc """
  `wardrik vault`: the secrets `WardrikVault` keeps, sealed, listed and
  removed on the daemon.

  `vault put NAME` asks for the value without showing it, or reads it from
  standard input where that is not a terminal, less the line ending it ends
  with. `vault put NAME=VALUE` takes it from the command line, where it stays
  in the shell's history and, while the command runs, in the list of
  processes. Neither prints the value back.

  A secret is the deployment's, which an agent's `credential: NAME` reads
  only where `vault.shared` in `config.yaml` names it. `--org ORG` seals it
  for an org, whose own agents read it, and `--user USER` for a user, whose
  agents read it: within `--org ORG`, or the deployment's org without it. An
  agent reads its owner's alone, never its org's for a user's agent. An org or a user is one segment of an agent's
  key, and is shown as the key shows it, `acme` or `acme/@jon`. An account a
  user connects is kept in the vault too, and listed with the rest.

  `vault ls` names each secret and whose it is. A user's secret is written
  under a hash of who they are, so `vault ls` counts users' secrets by name,
  and `vault ls --user USER` lists one user's.

  Where the vault has no key, the first `put` asks to make one, and keeps it
  in the data home; see `WardrikDaemon.VaultKey`. `--yes` makes it without
  asking. Where no one can answer and `--yes` is not given, `put` says how to
  give the vault a key instead.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Config
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.VaultKey

  @owner [org: :string, user: :string]
  @one_at_a_time "wardrik vault put asks for one value at a time: give NAME alone, or NAME=VALUE for each"

  @doc "The vault commands, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "vault put",
        group: "Tokens and secrets",
        arguments: "NAME[=VALUE]...",
        options: "[--org ORG] [--user USER] [--yes]",
        summary: "seal secrets in the vault, asking for a value not given",
        details: [
          "NAME alone asks for its value without showing it, or reads it from standard",
          "input where that is not a terminal. NAME=VALUE stays in your shell's history.",
          "A secret is the deployment's, which agents read only where vault.shared names it.",
          "--org ORG seals it for an org, whose own agents read it, and --user USER for a",
          "user, whose agents read it, within --org ORG or the deployment's org.",
          "Where the vault has no key, it asks to make one; --yes makes it without asking."
        ],
        switches: [yes: :boolean] ++ @owner,
        count: {1, :any},
        run: &put/2,
        live: &put_asked/3
      },
      %Command{
        name: "vault ls",
        group: "Tokens and secrets",
        options: "[--org ORG] [--user USER]",
        summary: "the vault's secrets and whose they are, never their values",
        details: [
          "Users' secrets are counted by name; --user USER lists one user's. With --json,",
          "each as its name, kind, and owner as --org and --user take it, or the count of",
          "users with it; the deployment's say whether the daemon's environment sets them."
        ],
        switches: @owner,
        run: &ls/2,
        json: &documents/2
      },
      %Command{
        name: "vault rm",
        group: "Tokens and secrets",
        arguments: "NAME",
        options: "[--org ORG] [--user USER]",
        summary: "remove a secret from the vault",
        switches: @owner,
        count: {1, 1},
        run: &rm/2
      }
    ]
  end

  # -- put ---------------------------------------------------------------------

  # Over erl_call: values given on the command line, sealed with a key the
  # vault has, or makes with --yes. Anything to ask runs live.
  defp put(words, opts) do
    with {:ok, owner} <- owner(opts),
         {:ok, pairs} when is_list(pairs) <- given(words),
         {:ok, notes, vault} <- key(opts, nil) do
      seal(vault, pairs, owner, notes, opts)
    else
      {:ok, {:ask, _name}} -> :live
      other -> other
    end
  end

  defp put_asked(words, opts, terminal) do
    with {:ok, owner} <- owner(opts),
         {:ok, given} <- given(words),
         {:ok, notes, vault} <- key(opts, terminal),
         :ok <- Enum.each(notes, &Terminal.puts(terminal, &1)),
         {:ok, pairs} <- value(given, terminal) do
      seal(vault, pairs, owner, [], opts)
    else
      :declined -> {:ok, "Nothing was sealed."}
      other -> other
    end
  end

  # The names and values a put gives, or the one name whose value it asks for.
  defp given([word]) do
    case String.split(word, "=", parts: 2) do
      [name] -> {:ok, {:ask, name}}
      _pair -> pairs([word])
    end
  end

  defp given(words), do: pairs(words)

  defp pairs(words) do
    words
    |> Enum.reduce_while([], fn word, pairs ->
      case String.split(word, "=", parts: 2) do
        [name, value] when name != "" and value != "" ->
          {:cont, [{name, value} | pairs]}

        [name, ""] when name != "" ->
          {:halt, {:error, "#{name}= gives no value; wardrik vault put #{name} asks for it"}}

        _bare_or_nameless ->
          {:halt, {:error, @one_at_a_time}}
      end
    end)
    |> case do
      pairs when is_list(pairs) -> {:ok, Enum.reverse(pairs)}
      {:error, message} -> {:error, message}
    end
  end

  defp value(pairs, _terminal) when is_list(pairs), do: {:ok, pairs}

  defp value({:ask, name}, %Terminal{input?: true} = terminal) do
    with {:ok, typed} <- Terminal.secret(terminal, "#{name}, which is not shown as you type: ") do
      {:ok, if(typed, do: [{name, typed}], else: [])}
    end
  end

  defp value({:ask, name}, %Terminal{}) do
    case IO.read(:eof) do
      text when is_binary(text) and text not in ["", "\n", "\r\n"] ->
        {:ok, [{name, String.replace(text, ~r/\r?\n\z/, "")}]}

      _empty ->
        {:error,
         "Nothing came on standard input to seal. Pipe the value in, as in:\n" <>
           "  printf %s \"$VALUE\" | wardrik vault put #{name}"}
    end
  end

  defp seal(_vault, [], _owner, _notes, _opts), do: {:ok, "Nothing was sealed."}

  # The audit names who sealed it, in the log of the host they reached.
  defp seal(vault, pairs, {kind, owner}, notes, opts) do
    by = opts[:by]
    audit = Wardrik.Host.audit(opts[:session].host)
    live? = WardrikVault.ready?(Wardrik.Host.credentials(opts[:session].host))

    pairs
    |> Enum.reduce_while(Enum.reverse(notes), fn {name, value}, lines ->
      case WardrikVault.put(vault, name, owner, value: value) do
        :ok ->
          :ok = Audit.record(audit, {:secret_stored, name, prefix(owner)}, by: by)
          {:cont, [sealed(kind, name, owner, live?) | lines]}

        {:error, reason} ->
          {:halt, {lines, "#{name} was not sealed: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {lines, failed} -> {:error, lines |> Enum.reverse([failed]) |> Enum.join("\n")}
      lines -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  defp sealed(:deployment, name, nil, live?) do
    cond do
      System.get_env(name) ->
        "Sealed #{name}. The daemon's environment sets #{name} too, which ${#{name}} and " <>
          "model providers read before the vault."

      Secrets.key?(name) and live? ->
        "Sealed #{name}. Model calls read it now."

      Secrets.key?(name) ->
        "Sealed #{name}. Model calls read it once the daemon restarts."

      read_at_start?(name) ->
        "Sealed #{name}. config.yaml's ${#{name}} reads it when the daemon next starts."

      true ->
        "Sealed #{name}."
    end
  end

  defp sealed(_kind, name, owner, _live?), do: "Sealed #{name} for #{shown(owner)}."

  # -- the key -----------------------------------------------------------------

  # Lines to say before sealing, and the vault to seal with: the daemon's,
  # where it has a key, else one with the key file's key, made where there is
  # none; :live where asking to make one needs a terminal.
  defp key(opts, terminal) do
    vault = Wardrik.Host.credentials(opts[:session].host)
    data_dir = opts[:config].data_dir

    cond do
      WardrikVault.ready?(vault) ->
        {:ok, [], vault}

      WardrikVault.configured?(vault) ->
        {:error,
         "The vault's key is not one it can use, 32 bytes in base64. " <>
           "wardrik doctor says where it comes from."}

      (keys = VaultKey.keys(data_dir)) != [] ->
        {:ok, restart(), %{vault | keys: keys}}

      true ->
        make(%{vault | keys: []}, data_dir, opts[:yes], terminal)
    end
  end

  defp make(vault, data_dir, true, _terminal), do: made(vault, data_dir)
  defp make(_vault, _data_dir, _yes, nil), do: :live

  defp make(_vault, _data_dir, _yes, %Terminal{input?: false}) do
    {:error,
     Enum.join(
       ["The vault has no key, and wardrik vault put --yes makes one." | why_a_key()],
       "\n"
     )}
  end

  defp make(vault, data_dir, _yes, terminal) do
    Terminal.puts(terminal, Enum.join(["The vault has no key." | why_a_key()], "\n"))

    if Owl.IO.confirm(message: "Make one?", default: true),
      do: made(vault, data_dir),
      else: :declined
  end

  defp why_a_key, do: Enum.map(VaultKey.about(), &("  " <> &1))

  defp made(vault, data_dir) do
    with {:ok, file} <- VaultKey.make(data_dir) do
      {:ok, ["Made a vault key, in #{file}." | restart()],
       %{vault | keys: VaultKey.keys(data_dir)}}
    end
  end

  # The daemon took its vault's keys as it started, so it reads what this
  # seals once it starts again. A node on another host needs a copy.
  defp restart do
    [
      "The daemon reads it once restarted: wardrik stop, then wardrik start.",
      "A node on another host needs a copy of #{VaultKey.file()}, as the cookie is, " <>
        "or give every node vault.keys."
    ]
  end

  defp read_at_start?(name) do
    with {:ok, file} <- Config.file(Config.config_dir()),
         {:ok, text} <- File.read(file) do
      String.contains?(text, "${#{name}}")
    else
      {:error, _none_or_both} -> false
    end
  end

  # -- ls and rm ---------------------------------------------------------------

  defp ls(_words, opts) do
    with {:ok, secrets} <- listed(opts) do
      {:ok, listing(rows(secrets), opts)}
    end
  end

  defp documents(_words, opts) do
    with {:ok, secrets} <- listed(opts) do
      {:ok, %{"secrets" => Enum.map(rows(secrets), &document/1)}}
    end
  end

  # Every secret, or those of the owner --org or --user names.
  defp listed(opts) do
    if opts[:org] || opts[:user] do
      with {:ok, {kind, owner}} <- owner(opts),
           do:
             {:ok, for(name <- WardrikVault.names(vault(opts), owner), do: {{kind, name}, owner})}
    else
      {:ok,
       for({name, owner} <- WardrikVault.list(vault(opts)), do: {{kind(owner), name}, owner})}
    end
  end

  # A row each, those written under a hash of their owner counted by name.
  defp rows(secrets) do
    {hashed, owned} = Enum.split_with(secrets, &match?({_ref, :hashed}, &1))

    counted =
      for {ref, count} <- Enum.frequencies_by(hashed, &elem(&1, 0)), do: {ref, {:hashed, count}}

    Enum.sort_by(owned ++ counted, fn {{kind, name}, _owner} ->
      {name, kind != :deployment, kind}
    end)
  end

  defp listing([], opts) do
    case owner(opts) do
      {:ok, {:deployment, nil}} -> "The vault holds no secrets. wardrik vault put NAME seals one."
      {:ok, {_kind, owner}} -> "The vault holds no secrets for #{shown(owner)}."
    end
  end

  defp listing(rows, _opts) do
    width = rows |> Enum.map(fn {{_kind, name}, _owner} -> String.length(name) end) |> Enum.max()
    total = Enum.sum_by(rows, &count/1)

    lines =
      for {{_kind, name} = ref, owner} <- rows,
          do: "  " <> String.pad_trailing(name, width) <> "  " <> whose(ref, owner)

    Enum.join(["#{total} #{if total == 1, do: "secret", else: "secrets"}:" | lines], "\n")
  end

  defp count({_ref, {:hashed, count}}), do: count
  defp count(_row), do: 1

  defp whose({:deployment, name}, nil) do
    if System.get_env(name),
      do: "the deployment's; the daemon's environment sets it too",
      else: "the deployment's"
  end

  defp whose({kind, _name}, {:hashed, 1}), do: "1 #{kind}'s"
  defp whose({kind, _name}, {:hashed, count}), do: "#{count} #{kind}s'"
  defp whose(_ref, owner), do: "#{shown(owner)}'s"

  defp document({{:deployment, name}, nil}),
    do: %{"name" => name, "kind" => "deployment", "environment" => System.get_env(name) != nil}

  defp document({{kind, name}, {:hashed, count}}),
    do: %{"name" => name, "kind" => Atom.to_string(kind), "count" => count}

  defp document({{kind, name}, owner}),
    do: %{"name" => name, "kind" => Atom.to_string(kind), "owner" => shown(owner)}

  defp rm([name], opts) do
    with {:ok, {kind, owner}} <- owner(opts) do
      for_owner = if kind == :deployment, do: "", else: " for #{shown(owner)}"

      if name in WardrikVault.names(vault(opts), owner) do
        :ok = removed(vault(opts), kind, name, owner)

        :ok =
          Audit.record(
            Wardrik.Host.audit(opts[:session].host),
            {:secret_removed, name, prefix(owner)},
            by: opts[:by]
          )

        {:ok, "Removed #{name}#{for_owner}."}
      else
        {:error, "The vault holds no #{name}#{for_owner}."}
      end
    end
  end

  defp removed(vault, _kind, name, owner), do: WardrikVault.forget(vault, name, owner)

  defp vault(opts), do: Wardrik.Host.credentials(opts[:session].host)

  # -- owners ------------------------------------------------------------------

  # Whose a secret is, as whose kind it is and its owner: the deployment's,
  # an org's, or a user's.
  defp owner(opts) do
    with :ok <- segment(opts[:org], "--org", "an org's", ""),
         :ok <-
           segment(
             opts[:user],
             "--user",
             "a user's",
             " A user within an org is --org ORG --user USER."
           ),
         :ok <- declared(opts[:org]) do
      case {opts[:org], opts[:user]} do
        {nil, nil} -> {:ok, {:deployment, nil}}
        {org, nil} -> {:ok, {:org, org}}
        {org, user} -> {:ok, {:user, user(org, user)}}
      end
    end
  end

  defp declared(nil), do: :ok
  defp declared(org), do: WardrikDaemon.Config.declared(WardrikDaemon.Host.config(), org)

  defp segment(nil, _flag, _whose, _hint), do: :ok

  defp segment(text, flag, whose, hint) do
    if Wardrik.AgentID.segment?(text),
      do: :ok,
      else:
        {:error,
         "#{flag} #{text} is not #{whose} name: a name holds no / or whitespace, and does " <>
           "not begin with @ or _." <> hint}
  end

  # The org and user a user's agents read their own secrets as, as their IDs
  # carry them: without --org, the deployment's org.
  defp user(org, user) do
    id =
      Wardrik.AgentID.new!("vault",
        org: org || WardrikDaemon.Config.org(WardrikDaemon.Host.config()),
        user: user
      )

    {id.org, id.user}
  end

  # The agents whose secret it is, the deployment's being every agent's.
  defp prefix(nil), do: Prefix.all()
  defp prefix(org) when is_binary(org), do: Prefix.new!(org: org)
  defp prefix({org, user}), do: Prefix.new!(org: org, user: user)

  defp kind(nil), do: :deployment
  defp kind(owner) when is_binary(owner), do: :org
  defp kind(_hashed), do: :user

  # An owner as an agent's key shows it.
  defp shown({org, user}), do: "#{org}/@#{user}"
  defp shown(owner), do: to_string(owner)
end
