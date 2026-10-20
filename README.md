# nu-git-auto-fetch

Background `git fetch` from the Nushell prompt.

Whenever a prompt is drawn inside a git repository whose last fetch is older
than an interval (5 minutes by default), nu-git-auto-fetch starts `git fetch`
as a Nushell background job. The prompt never waits for it, and remote-tracking
branches (`origin/main`, ahead/behind counts in your prompt, ...) stay
reasonably fresh without fetching by hand. It is a plain Nushell module that
only installs a `pre_prompt` hook.

## Requirements

- The latest Nushell release (0.116.0 or newer; uses `job spawn`)
- git 2.31 or newer
- Linux; macOS should work but is untested

## Install

Clone the repository:

```sh
git clone https://github.com/yutkat/nu-git-auto-fetch.git /path/to/nu-git-auto-fetch
```

then add to your `config.nu`:

```nu
use /path/to/nu-git-auto-fetch/nu-git-auto-fetch
nu-git-auto-fetch enable
```

Or install it with [nupm](https://github.com/nushell/nupm) from the clone
(`$env.NUPM_HOME/modules` must be in `$env.NU_LIB_DIRS`):

```nu
nupm install /path/to/nu-git-auto-fetch --path
```

and add to your `config.nu`:

```nu
use nu-git-auto-fetch
nu-git-auto-fetch enable
```

`use` alone changes nothing. To try it without your own configuration:

```sh
nu --config examples/minimal-config.nu
```

## Usage

```nu
nu-git-auto-fetch enable                           # fetch at most every 5 minutes per repository
nu-git-auto-fetch enable --interval 10min          # choose the interval
nu-git-auto-fetch enable --trusted [~/src ~/work]  # fetch only inside these directories
nu-git-auto-fetch status                           # state, and the current repository's last fetch
nu-git-auto-fetch disable                          # remove the hook
```

`--trusted` limits fetching to repositories in or below the given
directories (compared by path components, so `~/src` does not cover
`~/src2`); elsewhere the hook does not even run git. Without it, every
repository is fetched. Running `enable` again replaces the previous hook and
trusted directories without duplicates. The hook
is a `{code: ...}` record marked with a `__nu_git_auto_fetch` field, so
`disable` removes only that entry and keeps your own `pre_prompt` hooks,
including ones added after `enable`.

## How it works

On each prompt the hook runs one `git rev-parse` (a few milliseconds; nothing
else happens outside a repository or outside the trusted directories) and
starts a fetch when all of these hold:

- `FETCH_HEAD` is missing or older than the interval. In a linked worktree, a
  fetch from the main worktree or any other worktree of the same repository
  counts, because they share remote-tracking branches.
- No fetch was started for the repository during the last interval in this
  session. A fetch that fails (offline, no remote, authentication required) is
  therefore retried only once per interval, not on every prompt.
- No fetch job for the same repository is still running (checked with
  `job list`, by the job's description). Worktrees of one repository share a
  single job; a submodule is a separate repository.

The fetch runs `git fetch --quiet` for the current branch's remote (never all
remotes, even with `fetch.all`) and does not recurse into submodules; each
submodule is fetched when you enter it. Output is discarded, stdin is closed,
and the environment never prompts:

| Variable              | Value                    | Effect                                                   |
| --------------------- | ------------------------ | -------------------------------------------------------- |
| `GIT_TERMINAL_PROMPT` | `0`                      | no username/password prompt on the terminal              |
| `GIT_ASKPASS`         | empty                    | no graphical askpass program (`SSH_ASKPASS`)             |
| `GCM_INTERACTIVE`     | `never`                  | no Git Credential Manager dialog                         |
| `GIT_SSH_COMMAND`     | `<ssh> -o BatchMode=yes` | ssh fails instead of asking for a passphrase or host key |
| `GIT_ALLOW_PROTOCOL`  | `file:http:https:ssh`    | other transports (`git://`, `ext::`, ...) are refused    |

`<ssh>` is your own ssh command: a non-empty `GIT_SSH_COMMAND`, else the
repository's `core.sshCommand`, else `ssh`. A `GIT_ALLOW_PROTOCOL` you set
yourself is kept instead. Credential helpers and ssh-agent
keys still work. Running fetches show up in `job list` as
`nu-git-auto-fetch: <git dir>`, and `disable` lets them finish.

## Security

Entering a repository runs `git fetch` in it, and git honors that
repository's own `.git` directory, which can configure commands to run. An
untrusted repository, such as one extracted from an archive, could run them
when you `cd` into it. Prompts that run `git status` have the same kind of
exposure, but a fetch widens it.

The fetch therefore neutralizes the repository settings that git would run
during it:

- hooks, including `core.hooksPath` (`-c core.hooksPath=/dev/null`, which also
  covers auto maintenance), and `core.fsmonitor`
- `remote.<name>.uploadpack` (`--upload-pack git-upload-pack`)
- non-standard transports, including `ext::` and `core.gitProxy` for `git://`
  (`GIT_ALLOW_PROTOCOL`)
- submodule recursion (`--no-recurse-submodules`)

Still honored, because legitimate per-repository setups (such as one account
per repository) depend on them: credential helpers (`credential.helper`) and
`core.sshCommand` configured in the repository. Restrict fetching to
directories you trust with `enable --trusted`, or run
`nu-git-auto-fetch disable` before entering untrusted repositories.

## Known issues

- `GIT_SSH` (an ssh program path) is ignored during the fetch, because the
  `GIT_SSH_COMMAND` set for it takes precedence. Use `GIT_SSH_COMMAND` or
  `core.sshCommand` instead.
- `-o BatchMode=yes` is appended to your ssh command, so a command that does
  not accept ssh options (such as plink) fails to fetch.
- A `remote.<name>.uploadpack` you configured is not used; the remote's
  `git-upload-pack` must be on its default path.
- With `GIT_ALLOW_PROTOCOL` unset, remotes using other transports (`git://`,
  remote helpers such as `hg::`) are not fetched. Set `GIT_ALLOW_PROTOCOL`
  yourself to allow them.
- A fetch that hangs on the network is not killed; while it runs, no other
  fetch starts for that repository. Use `job kill` if needed.

## Development

```sh
nu tests/run.nu
```
