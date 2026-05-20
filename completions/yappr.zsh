#compdef yappr
# zsh completion for yappr

_yappr() {
  local state

  _arguments \
    '1: :->subcommand' \
    '*: :->args'

  case $state in
    subcommand)
      local subcommands=(
        'dictate:Record and type cleaned text at cursor'
        'daemon:Manage the STT daemon'
        'config:Manage configurations'
        'stats:Show dictation metrics'
        'trace:Show timing trace'
        'doctor:Post-install health check'
        'server:Manage the MLX inference server'
        'help:Show help'
        'version:Show version'
      )
      _describe 'subcommand' subcommands ;;
    args)
      case ${words[2]} in
        daemon|server)
          local cmds=('start' 'stop' 'restart' 'status' 'logs' 'tail')
          _describe 'operation' cmds ;;
        config)
          local cmds=('list' 'use' 'show')
          _describe 'operation' cmds ;;
      esac ;;
  esac
}

_yappr "$@"
