#! /bin/bash

do_playbook(){
	local NPC_SETUP_TMP="$(mktemp -d)" && trap "rm -fr '$NPC_SETUP_TMP'" EXIT
	local ARGS=() ARG
	while ARG="$1" && shift; do
		case "$ARG" in
		--stdin|-)
			local PLAYBOOK="$NPC_SETUP_TMP/stdin.yml"
			cat>"$PLAYBOOK" && ARGS=("${ARGS[@]}" "$PLAYBOOK")
			;;
		*)
			ARGS=("${ARGS[@]}" "$ARG")
			;;
		esac
	done
	export NPC_SETUP_LOG="$NPC_SETUP_TMP/setup.log" && mkfifo "$NPC_SETUP_LOG" && {
		cat "$NPC_SETUP_LOG" >&2 & ( exec 100>$NPC_SETUP_LOG && ansible-playbook "${ARGS[@]}" )
	}
}
do_playbook "$@"
