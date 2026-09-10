# Reuse one ssh-agent across all shells/tmux panes instead of spawning a new
# one (and leaking it) every time a shell starts. The agent's env vars are
# cached in ~/.ssh/agent-env.fish; a new agent is only started if none of the
# cached one is still reachable. Keys are NOT preloaded here: ssh_config sets
# `AddKeysToAgent yes`, so a key's passphrase is only asked for the first time
# that key is actually used, and the decrypted key is then cached in this
# same agent for the rest of its lifetime.
status is-interactive; or exit

set -l agent_env ~/.ssh/agent-env.fish

if test -f $agent_env
    source $agent_env
end

ssh-add -l >/dev/null 2>&1
if test $status -eq 2
    # No agent reachable (or none cached yet) -> start a fresh one and
    # remember it for the next shell.
    ssh-agent -c | string match -v 'echo *' >$agent_env
    source $agent_env
end
