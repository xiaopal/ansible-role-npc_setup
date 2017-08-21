#! /bin/bash
export NPC_SETUP_LOG="$(mktemp -u)" && mkfifo "$NPC_SETUP_LOG" && trap "rm -f '$NPC_SETUP_LOG'" EXIT && {
	cat "$NPC_SETUP_LOG" >&2 & ( exec 100>$NPC_SETUP_LOG && ansible-playbook "$@" )
}
