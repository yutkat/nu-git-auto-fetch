# Minimal config to try nu-git-auto-fetch without any other customization:
#
#   XDG_CONFIG_HOME=$(mktemp -d) nu --config examples/minimal-config.nu
#
# In your own config.nu, replace the path below with where you cloned the repo,
# or put the clone's parent directory in $env.NU_LIB_DIRS and `use nu-git-auto-fetch`.

$env.config.show_banner = false

use ../nu-git-auto-fetch
# Fetches the current repository in the background at most every 5 minutes.
# Use `nu-git-auto-fetch enable --interval 10min` to change the interval.
nu-git-auto-fetch enable
