# Environment
export PATH="$HOME/.local/bin:$PATH"
export EDITOR="nano"
export VISUAL="nano"

# History
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt INTERACTIVE_COMMENTS

# Completion
mkdir -p "$HOME/.cache/zsh"

autoload -Uz compinit
compinit -d "$HOME/.cache/zsh/zcompdump-$ZSH_VERSION"

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list \
	'm:{a-zA-Z}={A-Za-z}' \
	'r:|[._-]=* r:|=*'

autoload -Uz up-line-or-beginning-search
autoload -Uz down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

bindkey -e
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search

# Navigation
alias ..='cd ..'
alias ...='cd ../..'

# Autosuggestions
if [[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

# Runtime version manager
if (( $+commands[mise] )); then
  eval "$(mise activate zsh)"
fi

# Prompt
if (( $+commands[starship] )); then
  eval "$(starship init zsh)"
fi

# Syntax highlighting must be loaded last.
if [[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
