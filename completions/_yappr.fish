# fish completion for yappr
complete -c yappr -f
complete -c yappr -n '__fish_use_subcommand' -a dictate  -d 'Record and type cleaned text'
complete -c yappr -n '__fish_use_subcommand' -a daemon   -d 'Manage STT daemon'
complete -c yappr -n '__fish_use_subcommand' -a config   -d 'Manage configurations'
complete -c yappr -n '__fish_use_subcommand' -a stats    -d 'Show dictation metrics'
complete -c yappr -n '__fish_use_subcommand' -a trace    -d 'Show timing trace'
complete -c yappr -n '__fish_use_subcommand' -a doctor   -d 'Post-install health check'
complete -c yappr -n '__fish_use_subcommand' -a server   -d 'Manage MLX inference server'
complete -c yappr -n '__fish_use_subcommand' -a help     -d 'Show help'
complete -c yappr -n '__fish_use_subcommand' -a version  -d 'Show version'

for sub in daemon server
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a start   -d 'Start'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a stop    -d 'Stop'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a restart -d 'Restart'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a status  -d 'Check status'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a logs    -d 'Print log'
  complete -c yappr -n "__fish_seen_subcommand_from $sub" -a tail    -d 'Follow log'
end

complete -c yappr -n '__fish_seen_subcommand_from config' -a list  -d 'List configs'
complete -c yappr -n '__fish_seen_subcommand_from config' -a use   -d 'Switch config'
complete -c yappr -n '__fish_seen_subcommand_from config' -a show  -d 'Show active config'
