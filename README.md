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

Clone the repository, then add to your `config.nu`:

```nu
use /path/to/nu-git-auto-fetch/nu-git-auto-fetch
nu-git-auto-fetch enable
```

`use` alone changes nothing. To try it without your own configuration:

```sh
nu --config examples/minimal-config.nu
```

## Usage

```nu
nu-git-auto-fetch enable                   # fetch at most every 5 minutes per repository
nu-git-auto-fetch enable --interval 10min  # choose the interval
nu-git-auto-fetch status                   # state, and the current repository's last fetch
nu-git-auto-fetch disable                  # remove the hook
```

Running `enable` again replaces the previous hook without duplicates. The hook
is a `{code: ...}` record marked with a `__nu_git_auto_fetch` field, so
`disable` removes only that entry and keeps your own `pre_prompt` hooks,
including ones added after `enable`.

## How it works

On each prompt the hook runs one `git rev-parse` (a few milliseconds; nothing
else happens outside a repository) and starts a fetch when all of these hold:

- `FETCH_HEAD` is missing or older than the interval. In a linked worktree, a
  fetch from the main worktree or any other worktree of the same repository
  counts, because they share remote-tracking branches.
- No fetch was started for the repository during the last interval in this
  session. A fetch that fails (offline, no remote, authentication required) is
  therefore retried only once per interval, not on every prompt.
- No fetch job for the same repository is still running (checked with
  `job list`, by the job's description). Worktrees of one repository share a
  single job; a submodule is a separate repository.

The fetch runs `git fetch --quiet` in the current directory with output
discarded, stdin closed, and an environment that never prompts:

| Variable              | Value                  | Effect                                                   |
| --------------------- | ---------------------- | -------------------------------------------------------- |
| `GIT_TERMINAL_PROMPT` | `0`                    | no username/password prompt on the terminal              |
| `GIT_ASKPASS`         | empty                  | no graphical askpass program (`SSH_ASKPASS`)             |
| `GIT_SSH_COMMAND`     | `ssh -o BatchMode=yes` | ssh fails instead of asking for a passphrase or host key |

Credential helpers and ssh-agent keys still work. Running fetches show up in
`job list` as `nu-git-auto-fetch: <git dir>`, and `disable` lets them finish.

## Known issues

- `GIT_SSH_COMMAND` replaces a `core.sshCommand` you configured in git.
- A fetch that hangs on the network is not killed; while it runs, no other
  fetch starts for that repository. Use `job kill` if needed.

## Development

```sh
nu tests/run.nu
```
