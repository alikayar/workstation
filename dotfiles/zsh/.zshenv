# Silent runtime discovery for interactive shells, SSH commands and agents.
# Shims resolve versions for the working directory without interactive hooks.
typeset -U path PATH
path=("${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims" "$HOME/.local/bin" $path)
# An inherited Python environment remains authoritative in child shells.
if [[ -n ${VIRTUAL_ENV:-} && -d "$VIRTUAL_ENV/bin" ]]; then
  path=("$VIRTUAL_ENV/bin" $path)
fi
export PATH
