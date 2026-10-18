# Test entry point: `nu tests/run.nu`. Exits non-zero when a test fails.
#
# These tests drive the hook body and enable/disable on `$env.config`
# in-process, against throwaway repositories whose remotes are local
# directories (no network). Nushell only runs pre_prompt hooks in an
# interactive session, so the hook itself firing needs one.

use std/assert

const ROOT = path self ..
use ($ROOT | path join nu-git-auto-fetch)
use ($ROOT | path join nu-git-auto-fetch fetch.nu) *

# Keep the user's git configuration (signing, hooks, ...) out of the fixtures.
$env.GIT_CONFIG_GLOBAL = "/dev/null"
$env.GIT_CONFIG_NOSYSTEM = "1"
$env.GIT_AUTHOR_NAME = "test"
$env.GIT_AUTHOR_EMAIL = "test@example.com"
$env.GIT_COMMITTER_NAME = "test"
$env.GIT_COMMITTER_EMAIL = "test@example.com"

def ours []: list -> list { where {|h| $h | is-ours } }

def commit [dir: path]: nothing -> nothing {
    ^git -C $dir commit --quiet --allow-empty -m commit
}

# An upstream repository with one commit and a clone of it that was never
# fetched. Returns {root, up, clone}.
def fixture []: nothing -> record {
    let root = mktemp -d
    let up = $root | path join up
    let clone = $root | path join clone
    ^git init --quiet $up
    commit $up
    ^git clone --quiet $up $clone
    {root: $root, up: $up, clone: $clone}
}

# Make every fetch from `clone` take at least `seconds`.
def slow-remote [clone: path, seconds: int]: nothing -> nothing {
    ^git -C $clone config remote.origin.uploadpack $"sleep ($seconds); git-upload-pack"
}

def fetch-jobs []: nothing -> list {
    job list | where {|j| ($j.description? | default "") | str starts-with $JOB_PREFIX }
}

def wait-fetches []: nothing -> nothing {
    let deadline = (date now) + 20sec
    while (fetch-jobs | is-not-empty) {
        if (date now) > $deadline { error make {msg: "fetch jobs did not finish"} }
        sleep 50ms
    }
}

def rev [dir: path, ref: string]: nothing -> string {
    ^git -C $dir rev-parse $ref | str trim
}

# --- pure helpers -----------------------------------------------------------

def "test is due when never fetched nor tried" [] {
    assert (is-due null null 5min (date now))
}

def "test is due only after the interval" [] {
    let now = date now
    assert not (is-due ($now - 4min) null 5min $now)
    assert (is-due ($now - 5min) null 5min $now)
    assert (is-due ($now - 1hr) null 5min $now)
}

def "test a recent attempt postpones the fetch" [] {
    let now = date now
    assert not (is-due null ($now - 1min) 5min $now)
    assert not (is-due ($now - 1hr) ($now - 1min) 5min $now)
    assert (is-due ($now - 1hr) ($now - 6min) 5min $now)
}

def "test only marked records are ours" [] {
    assert ({code: {|| 1 }, $MARKER: true} | is-ours)
    assert not ({code: {|| 1 }} | is-ours)
    assert not ({code: {|| 1 }, $MARKER: false} | is-ours)
    assert not ({|| 1 } | is-ours)
    assert not ("print hi" | is-ours)
}

def "test fetch never prompts" [] {
    assert equal $FETCH_ENV.GIT_TERMINAL_PROMPT "0"
    assert equal $FETCH_ENV.GIT_ASKPASS ""
    assert equal $FETCH_ENV.GIT_SSH_COMMAND "ssh -o BatchMode=yes"
}

# --- repository detection ---------------------------------------------------

def "test no repository outside git" [] {
    let dir = mktemp -d
    assert equal (repo-dirs $dir) null
    rm -r $dir
}

def "test repository dirs are absolute" [] {
    let f = fixture
    let sub = $f.clone | path join a b
    mkdir $sub
    let git_dir = $f.clone | path join .git
    assert equal (repo-dirs $sub) {git_dir: $git_dir, common_dir: $git_dir}
    rm -r $f.root
}

def "test linked worktree has its own git dir and shares the common dir" [] {
    let f = fixture
    let wt = $f.root | path join wt
    ^git -C $f.clone worktree add --quiet $wt
    let dirs = repo-dirs $wt
    assert equal $dirs.common_dir ($f.clone | path join .git)
    assert equal $dirs.git_dir ($f.clone | path join .git worktrees wt)
    rm -r $f.root
}

def "test submodule is its own repository" [] {
    let f = fixture
    ^git -C $f.clone -c protocol.file.allow=always submodule --quiet add $f.up sub
    let dirs = repo-dirs ($f.clone | path join sub)
    let git_dir = $f.clone | path join .git modules sub
    assert equal $dirs {git_dir: $git_dir, common_dir: $git_dir}
    rm -r $f.root
}

def "test last fetch is null before the first fetch" [] {
    let f = fixture
    assert equal (last-fetch (repo-dirs $f.clone)) null
    ^git -C $f.clone fetch --quiet
    assert equal (last-fetch (repo-dirs $f.clone) | describe) datetime
    rm -r $f.root
}

def "test worktrees see fetches of the main worktree" [] {
    let f = fixture
    let a = $f.root | path join a
    let b = $f.root | path join b
    ^git -C $f.clone worktree add --quiet $a
    ^git -C $f.clone worktree add --quiet $b
    ^git -C $a fetch --quiet
    assert equal (last-fetch (repo-dirs $b)) null "another linked worktree is not checked by default"
    assert equal (last-fetch --all-worktrees (repo-dirs $b) | describe) datetime
    assert equal (last-fetch --all-worktrees (repo-dirs $f.clone) | describe) datetime
    ^git -C $f.clone fetch --quiet
    assert equal (last-fetch (repo-dirs $b) | describe) datetime "the main worktree is always checked"
    rm -r $f.root
}

# --- the hook body ----------------------------------------------------------

def --env "test check does nothing outside a repository" [] {
    let dir = mktemp -d
    assert equal (check $dir) null
    assert equal (fetch-jobs | length) 0
    rm -r $dir
}

def --env "test check fetches a never fetched repository in the background" [] {
    let f = fixture
    commit $f.up
    slow-remote $f.clone 3
    let start = date now
    let id = check $f.clone
    assert ((date now) - $start < 1sec) "check returns before the fetch finishes"
    assert equal (fetch-jobs | get id) [$id]
    assert equal (fetch-jobs | get description) [$"($JOB_PREFIX)($f.clone | path join .git)"]
    wait-fetches
    assert equal (rev $f.clone origin/HEAD) (rev $f.up HEAD)
    rm -r $f.root
}

def --env "test check does not start a second fetch for a running one" [] {
    let f = fixture
    slow-remote $f.clone 2
    let wt = $f.root | path join wt
    ^git -C $f.clone worktree add --quiet $wt
    assert ((check $f.clone) != null)
    # Forget the attempt, so only the running job can prevent another fetch.
    $env.__NU_GIT_AUTO_FETCH = {enabled: true}
    assert equal (check $f.clone) null
    assert equal (check $wt) null "worktrees of the same repository share the job"
    assert equal (fetch-jobs | length) 1
    wait-fetches
    rm -r $f.root
}

def --env "test check does not fetch again within the interval" [] {
    let f = fixture
    ^git -C $f.clone fetch --quiet
    $env.__NU_GIT_AUTO_FETCH = {enabled: true, interval: 1hr}
    assert equal (check $f.clone) null
    $env.__NU_GIT_AUTO_FETCH = {enabled: true, interval: 1sec}
    sleep 1100ms
    assert ((check $f.clone) != null)
    wait-fetches
    rm -r $f.root
}

def --env "test a fetch in another worktree counts" [] {
    let f = fixture
    let a = $f.root | path join a
    let b = $f.root | path join b
    ^git -C $f.clone worktree add --quiet $a
    ^git -C $f.clone worktree add --quiet $b
    ^git -C $a fetch --quiet
    assert equal (check $b) null
    rm -r $f.root
}

def --env "test a failed fetch is not retried within the interval" [] {
    let f = fixture
    ^git -C $f.clone remote set-url origin ($f.root | path join missing)
    assert ((check $f.clone) != null)
    wait-fetches
    assert equal (check $f.clone) null
    assert equal ($env.__NU_GIT_AUTO_FETCH.attempts | columns) [($f.clone | path join .git)]
    rm -r $f.root
}

def --env "test a repository without remotes is tried once per interval" [] {
    let dir = mktemp -d
    ^git init --quiet $dir
    assert ((check $dir) != null)
    wait-fetches
    assert equal (check $dir) null
    rm -r $dir
}

def --env "test expired attempts are dropped" [] {
    let f = fixture
    let old = (date now) - 1hr
    $env.__NU_GIT_AUTO_FETCH = {enabled: true, interval: 5min, attempts: {"/gone/.git": $old}}
    assert ((check $f.clone) != null)
    assert equal ($env.__NU_GIT_AUTO_FETCH.attempts | columns) [($f.clone | path join .git)]
    wait-fetches
    rm -r $f.root
}

# --- enable / disable -------------------------------------------------------

def user-hook []: nothing -> closure { {|| $env.USER_HOOK = true } }

def --env "test use alone does not change config" [] {
    # The module is already imported at the top of this file.
    assert equal ($env.config.hooks.pre_prompt | ours | length) 0
    assert equal (nu-git-auto-fetch status | get enabled) false
}

def --env "test enable installs one marked pre_prompt hook" [] {
    $env.config.hooks.pre_prompt = [(user-hook)]
    nu-git-auto-fetch enable
    let hooks = $env.config.hooks.pre_prompt
    assert equal ($hooks | length) 2
    assert equal ($hooks | ours | length) 1
    assert equal ($hooks | last | columns | sort) ([code $MARKER] | sort)
    assert equal ($hooks | first | describe) closure "user hook kept in front"
    let st = nu-git-auto-fetch status
    assert equal $st.enabled true
    assert equal $st.interval 5min
    assert equal $st.hooks 1
}

def --env "test enable is idempotent" [] {
    $env.config.hooks.pre_prompt = [(user-hook)]
    nu-git-auto-fetch enable
    nu-git-auto-fetch enable
    nu-git-auto-fetch enable --interval 1min
    assert equal ($env.config.hooks.pre_prompt | length) 2
    assert equal ($env.config.hooks.pre_prompt | ours | length) 1
    assert equal (nu-git-auto-fetch status | get interval) 1min
}

def --env "test enable rejects a non-positive interval without changes" [] {
    nu-git-auto-fetch enable --interval 1min
    let before = $env.config
    let before_state = $env.__NU_GIT_AUTO_FETCH
    assert error { nu-git-auto-fetch enable --interval 0sec }
    assert error { nu-git-auto-fetch enable --interval -1min }
    assert equal $env.config $before
    assert equal $env.__NU_GIT_AUTO_FETCH $before_state
}

def --env "test the installed hook runs the check" [] {
    let f = fixture
    nu-git-auto-fetch enable
    cd $f.clone
    let hook = $env.config.hooks.pre_prompt | ours | first
    do --env $hook.code
    assert equal (fetch-jobs | length) 1
    assert equal ($env.__NU_GIT_AUTO_FETCH.attempts | columns) [($f.clone | path join .git)]
    wait-fetches
    cd ($f.root | path dirname)
    rm -r $f.root
}

def --env "test disable removes only its hook" [] {
    $env.config.hooks.pre_prompt = [(user-hook)]
    let before = $env.config.hooks.pre_prompt
    nu-git-auto-fetch enable
    nu-git-auto-fetch enable
    nu-git-auto-fetch disable
    assert equal $env.config.hooks.pre_prompt $before
    assert equal (nu-git-auto-fetch status | get enabled) false
}

def --env "test disable keeps hooks the user added after enable" [] {
    nu-git-auto-fetch enable
    $env.config.hooks.pre_prompt ++= [(user-hook)]
    nu-git-auto-fetch disable
    assert equal ($env.config.hooks.pre_prompt | length) 1
    assert equal ($env.config.hooks.pre_prompt | first | describe) closure
}

def --env "test disable without enable is a no-op" [] {
    $env.config.hooks.pre_prompt = [(user-hook)]
    let before = $env.config
    nu-git-auto-fetch disable
    assert equal $env.config $before
}

def --env "test status reports the current repository" [] {
    let f = fixture
    cd $f.clone
    let st = nu-git-auto-fetch status
    assert equal $st.repository ($f.clone | path join .git)
    assert equal $st.last_fetch null
    assert equal $st.running []
    slow-remote $f.clone 1
    check $f.clone
    assert equal (nu-git-auto-fetch status | get running) [($f.clone | path join .git)]
    wait-fetches
    assert equal (nu-git-auto-fetch status | get last_fetch | describe) datetime
    cd ($f.root | path dirname)
    rm -r $f.root
}

# --- runner -----------------------------------------------------------------

# Each test runs in its own closure, so `$env` changes do not leak between
# tests.
const TESTS = [
    "test is due when never fetched nor tried"
    "test is due only after the interval"
    "test a recent attempt postpones the fetch"
    "test only marked records are ours"
    "test fetch never prompts"
    "test no repository outside git"
    "test repository dirs are absolute"
    "test linked worktree has its own git dir and shares the common dir"
    "test submodule is its own repository"
    "test last fetch is null before the first fetch"
    "test worktrees see fetches of the main worktree"
    "test check does nothing outside a repository"
    "test check fetches a never fetched repository in the background"
    "test check does not start a second fetch for a running one"
    "test check does not fetch again within the interval"
    "test a fetch in another worktree counts"
    "test a failed fetch is not retried within the interval"
    "test a repository without remotes is tried once per interval"
    "test expired attempts are dropped"
    "test use alone does not change config"
    "test enable installs one marked pre_prompt hook"
    "test enable is idempotent"
    "test enable rejects a non-positive interval without changes"
    "test the installed hook runs the check"
    "test disable removes only its hook"
    "test disable keeps hooks the user added after enable"
    "test disable without enable is a no-op"
    "test status reports the current repository"
]

def --env run-test [name: string]: nothing -> any {
    try {
        match $name {
            "test is due when never fetched nor tried" => { test is due when never fetched nor tried }
            "test is due only after the interval" => { test is due only after the interval }
            "test a recent attempt postpones the fetch" => { test a recent attempt postpones the fetch }
            "test only marked records are ours" => { test only marked records are ours }
            "test fetch never prompts" => { test fetch never prompts }
            "test no repository outside git" => { test no repository outside git }
            "test repository dirs are absolute" => { test repository dirs are absolute }
            "test linked worktree has its own git dir and shares the common dir" => { test linked worktree has its own git dir and shares the common dir }
            "test submodule is its own repository" => { test submodule is its own repository }
            "test last fetch is null before the first fetch" => { test last fetch is null before the first fetch }
            "test worktrees see fetches of the main worktree" => { test worktrees see fetches of the main worktree }
            "test check does nothing outside a repository" => { test check does nothing outside a repository }
            "test check fetches a never fetched repository in the background" => { test check fetches a never fetched repository in the background }
            "test check does not start a second fetch for a running one" => { test check does not start a second fetch for a running one }
            "test check does not fetch again within the interval" => { test check does not fetch again within the interval }
            "test a fetch in another worktree counts" => { test a fetch in another worktree counts }
            "test a failed fetch is not retried within the interval" => { test a failed fetch is not retried within the interval }
            "test a repository without remotes is tried once per interval" => { test a repository without remotes is tried once per interval }
            "test expired attempts are dropped" => { test expired attempts are dropped }
            "test use alone does not change config" => { test use alone does not change config }
            "test enable installs one marked pre_prompt hook" => { test enable installs one marked pre_prompt hook }
            "test enable is idempotent" => { test enable is idempotent }
            "test enable rejects a non-positive interval without changes" => { test enable rejects a non-positive interval without changes }
            "test the installed hook runs the check" => { test the installed hook runs the check }
            "test disable removes only its hook" => { test disable removes only its hook }
            "test disable keeps hooks the user added after enable" => { test disable keeps hooks the user added after enable }
            "test disable without enable is a no-op" => { test disable without enable is a no-op }
            "test status reports the current repository" => { test status reports the current repository }
            _ => (error make {msg: $"no such test: ($name)"})
        }
        null
    } catch {|err| $err.msg }
}

def main [] {
    let results = $TESTS | each {|name| {name: $name, error: (do { run-test $name })} }
    for r in $results {
        if $r.error == null {
            print $"ok    ($r.name)"
        } else {
            print $"FAIL  ($r.name): ($r.error)"
        }
    }
    let failed = $results | where error != null | length
    print $"\n($results | length) tests, ($failed) failed"
    if $failed > 0 { exit 1 }
}
