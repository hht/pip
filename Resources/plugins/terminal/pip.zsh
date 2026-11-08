# Pip terminal plugin: pops a card (finished / failed) under the notch when a command runs for > 10s; click jumps back to terminal.
# Source this file in ~/.zshrc (provided after clicking "Install" in Pip Settings › Terminal). Leaves other shell behaviors untouched.
# Forwards command name (first word) only, never arguments; directory and exit code are passed as card facts.
# Modeled after zsh-auto-notify and ntfy shell-integration: preexec records start time and command name, precmd first line grabs $?.
# @see https://zsh.sourceforge.io/Doc/Release/Functions.html#Hook-Functions
#
# Configurable before source:
#   pip_min_seconds  minimum execution seconds to trigger alert (default: 10)
#   pip_ignore       command names to ignore (fullscreen, interactive)

[[ -o interactive ]] || return 0
zmodload zsh/datetime || return 0
autoload -Uz add-zsh-hook

typeset -g pip_min_seconds=${pip_min_seconds:-10}
(( ${+pip_ignore} )) || typeset -ga pip_ignore=(
  vim nvim vi nano emacs less more man ssh mosh top htop btop watch tmux screen claude lazygit tig fzf k9s yazi ranger
)
# This file lives in <Notchkeeper>/plugins/terminal/, pipctl in <Notchkeeper>/bin/
typeset -g _pip_pipctl=${${(%):-%x}:A:h:h:h}/bin/pipctl
typeset -g _pip_started _pip_command

_pip_preexec() {
  emulate -L zsh  # Unaffected by user shell options (shwordsplit, ksharrays, etc.)
  local word opts valued= skip=0 i
  _pip_command=
  # Skip environment variable assignments, parentheses, and prefixes like sudo and their options; options with values skip the value as well
  for word in ${(z)1}; do
    if (( skip )); then skip=0; continue; fi
    case $word in
      *=*|'('|'{'|'!') continue ;;
      command|builtin|noglob|nocorrect|time|nohup) valued=; continue ;;
      exec) valued=a; continue ;;
      sudo) valued=ughpCDrtTU; continue ;;
      env) valued=uSPC; continue ;;
      nice) valued=n; continue ;;
      -*)
        # Combined options (-iu): option taking value at end takes next word; within option, value is attached (-ualice)
        opts=${word#-}
        for (( i = 1; i <= $#opts; i++ )); do
          [[ $valued == *"${opts[i]}"* ]] || continue
          (( i == $#opts )) && skip=1
          break
        done
        continue ;;
    esac
    _pip_command=${word:t}
    break
  done
  _pip_started=$EPOCHREALTIME
}

_pip_precmd() {
  local exit_code=$?  # Must be first line: any subsequent command overwrites $?
  emulate -L zsh
  [[ -n $_pip_started && -n $_pip_command ]] || return 0
  local -F elapsed=$(( EPOCHREALTIME - _pip_started ))
  local command=$_pip_command
  _pip_started= _pip_command=
  (( elapsed >= pip_min_seconds )) || return 0
  (( ${pip_ignore[(Ie)$command]} )) && return 0
  [[ -x $_pip_pipctl ]] || return 0

  local -i seconds=$(( elapsed ))  # Truncate fraction on integer assignment
  local took
  if (( seconds >= 3600 )); then took="$(( seconds / 3600 )) h $(( seconds % 3600 / 60 )) m"
  elif (( seconds >= 60 )); then took="$(( seconds / 60 )) m $(( seconds % 60 )) s"
  else took="$seconds s"
  fi
  local title=$command outcome
  if (( exit_code == 0 )); then title+=" finished"; outcome=done
  else title+=" failed"; outcome=failed
  fi
  local -a args=(notify --plugin terminal --title $title --value $took --outcome $outcome
                 --fact "exit_code=$exit_code" --fact "cwd=${(%):-%~}")
  # Keep latest per terminal; click jumps back to this terminal. Only pop card if not macOS pseudo-terminal (/dev/ttysN)
  [[ $TTY == /dev/ttys<-> ]] && args+=(--group "tty:$TTY" --tty $TTY --pid $$ --cwd $PWD)
  # Background execution without entering jobs table, avoiding prompt lag
  "$_pip_pipctl" $args &>/dev/null &!
}

add-zsh-hook preexec _pip_preexec
add-zsh-hook precmd _pip_precmd
