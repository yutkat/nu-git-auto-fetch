# nu-git-auto-fetch: run `git fetch` in the background from the prompt.
#
# `use nu-git-auto-fetch` only defines commands; nothing changes until
# `nu-git-auto-fetch enable` is run.

use fetch.nu [MARKER JOB_PREFIX DEFAULT_INTERVAL state is-ours repo-dirs last-fetch check]

def pre-prompt-hooks []: nothing -> list {
    let hooks = $env.config.hooks?.pre_prompt?
    match ($hooks | describe | str replace -r '<.*' '') {
        list | table => $hooks
        nothing => []
        _ => [$hooks]
    }
}

# Enable background fetching for the current session.
#
# Adds a pre_prompt hook that, inside a git repository, starts `git fetch` as
# a background job when the last fetch is older than the interval. Running it
# again replaces the previous hook instead of adding another one.
export def --env enable [
    --interval: duration # Minimum time between fetches of a repository (default: 5min)
]: nothing -> nothing {
    let interval = $interval | default $DEFAULT_INTERVAL
    if $interval <= 0sec {
        error make {msg: $"interval must be positive, got ($interval)"}
    }
    let others = pre-prompt-hooks | where {|h| not ($h | is-ours) }
    let hook = {code: {|| check $env.PWD | ignore }} | insert $MARKER true
    $env.config.hooks.pre_prompt = $others ++ [$hook]
    $env.__NU_GIT_AUTO_FETCH = {enabled: true, interval: $interval, attempts: ((state).attempts? | default {})}
}

# Disable background fetching and remove the hook enable added.
#
# Other pre_prompt hooks are kept. Fetches that are already running finish.
export def --env disable []: nothing -> nothing {
    let hooks = pre-prompt-hooks
    if ($hooks | any {|h| $h | is-ours }) {
        $env.config.hooks.pre_prompt = $hooks | where {|h| not ($h | is-ours) }
    }
    if (state).enabled {
        $env.__NU_GIT_AUTO_FETCH = {enabled: false}
    }
}

# Show whether nu-git-auto-fetch is enabled, and the fetch state of the
# repository in the current directory.
export def status []: nothing -> record {
    let st = state
    let repo = repo-dirs $env.PWD
    let last = if $repo == null { null } else { last-fetch --all-worktrees $repo }
    {
        enabled: $st.enabled
        interval: ($st.interval? | default null)
        hooks: (pre-prompt-hooks | where {|h| $h | is-ours } | length)
        repository: ($repo.common_dir? | default null)
        last_fetch: $last
        running: (job list | each {|j| $j.description? | default "" } | where ($it | str starts-with $JOB_PREFIX) | str replace $JOB_PREFIX "")
    }
}
