# bash completion for yappr
_yappr_completions() {
  local cur prev subcommands
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  subcommands="dictate daemon config stats trace doctor server help version"

  if [[ $COMP_CWORD -eq 1 ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    return
  fi

  case "$prev" in
    daemon|server)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "start stop restart status logs tail" -- "$cur")) ;;
    config)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "list use show" -- "$cur")) ;;
    stats)
      # shellcheck disable=SC2207
      COMPREPLY=($(compgen -W "--metrics-dir --help" -- "$cur")) ;;
  esac
}
complete -F _yappr_completions yappr
