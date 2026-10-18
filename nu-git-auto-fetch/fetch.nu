# Repository detection and background fetching for nu-git-auto-fetch.

# Marker field on the pre_prompt hook record nu-git-auto-fetch installs.
export const MARKER = "__nu_git_auto_fetch"

# Prefix of the description of every fetch job nu-git-auto-fetch spawns.
export const JOB_PREFIX = "nu-git-auto-fetch: "

export const DEFAULT_INTERVAL = 5min

# Environment for the background fetch: never ask for credentials or host keys.
# An empty GIT_ASKPASS also keeps git from falling back to SSH_ASKPASS.
export const FETCH_ENV = {
    GIT_TERMINAL_PROMPT: "0"
    GIT_ASKPASS: ""
    GIT_SSH_COMMAND: "ssh -o BatchMode=yes"
}

export def state []: nothing -> record {
    $env.__NU_GIT_AUTO_FETCH? | default {enabled: false}
}

export def is-ours []: any -> bool {
    ($in | describe | str starts-with record) and ($in | get -o $MARKER) == true
}

# Absolute git dir and common git dir of the repository at `dir`, or null
# outside a repository. Linked worktrees have their own git dir (with its own
# FETCH_HEAD) but share remote-tracking refs through the common dir.
export def repo-dirs [dir: path]: nothing -> any {
    let r = try {
        ^git -C $dir rev-parse --path-format=absolute --git-dir --git-common-dir | complete
    } catch {
        return null
    }
    if $r.exit_code != 0 { return null }
    let lines = $r.stdout | lines
    if ($lines | length) != 2 { return null }
    {git_dir: $lines.0, common_dir: $lines.1}
}

def mtime [file: path]: nothing -> any {
    try { ls -D $file | get 0.modified } catch { null }
}

# Time of the most recent fetch into the repository, or null if it was never
# fetched. Only the current and the main worktree are checked unless
# `--all-worktrees` is given.
export def last-fetch [repo: record, --all-worktrees]: nothing -> any {
    mut dirs = [$repo.git_dir $repo.common_dir]
    if $all_worktrees {
        let linked = try { ls -s ($repo.common_dir | path join worktrees) | get name } catch { [] }
        $dirs ++= ($linked | each {|n| $repo.common_dir | path join worktrees $n })
    }
    let times = $dirs | uniq | each {|d| mtime ($d | path join FETCH_HEAD) } | compact
    if ($times | is-empty) { null } else { $times | math max }
}

# Whether a fetch job for the repository keyed by `common_dir` is still running.
export def fetch-running [common_dir: string]: nothing -> bool {
    job list | any {|j| $j.description? == $"($JOB_PREFIX)($common_dir)" }
}

# Whether a repository last fetched at `last` and last tried at `attempt`
# (either may be null) is due for a fetch at `now`.
export def is-due [last: any, attempt: any, interval: duration, now: datetime]: nothing -> bool {
    [$last $attempt] | compact | all {|t| $now - $t >= $interval }
}

# Start `git fetch` for the repository at `dir` as a background job and return
# its id. Output is discarded and stdin is closed.
export def spawn-fetch [dir: path, common_dir: string]: nothing -> int {
    job spawn --description $"($JOB_PREFIX)($common_dir)" {
        with-env $FETCH_ENV {
            try { null | ^git -C $dir fetch --quiet | complete | ignore }
        }
    }
}

# The pre_prompt hook body: fetch the repository at `dir` in the background
# when it is due. Returns the spawned job id, or null.
export def --env check [dir: path]: nothing -> any {
    let repo = repo-dirs $dir
    if $repo == null { return null }
    let st = state
    let interval = $st.interval? | default $DEFAULT_INTERVAL
    let attempts = $st.attempts? | default {}
    let key = $repo.common_dir
    let now = date now
    let attempt = $attempts | get -o $key
    let last = last-fetch $repo
    # Another worktree may have fetched recently; look there only when needed.
    let last = if (is-due $last null $interval $now) { last-fetch --all-worktrees $repo } else { $last }
    if not (is-due $last $attempt $interval $now) { return null }
    if (fetch-running $key) { return null }
    # Remember the attempt so a failing fetch (offline, no remote) is not
    # retried on every prompt. Expired attempts are dropped.
    let attempts = $attempts | transpose k t | where {|a| $now - $a.t < $interval } | reduce --fold {} {|a, acc| $acc | insert $a.k $a.t }
    $env.__NU_GIT_AUTO_FETCH = $st | upsert attempts ($attempts | upsert $key $now)
    spawn-fetch $dir $key
}
