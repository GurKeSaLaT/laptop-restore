# Ensures ~/.local/bin (e.g. the `claude` symlink) stays on PATH.
# Lives in conf.d/ deliberately: `update-dotfiles` (./setup install) does an
# `rsync -a --delete` over ~/.config/fish/ and only excludes conf.d/ from
# that wipe, so anything placed elsewhere (incl. fish_add_path's universal
# variable in fish_variables) gets deleted on every dotfiles update.
# See ~/config/arch-zfs-safe-updates.md.
if not contains -- $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end
