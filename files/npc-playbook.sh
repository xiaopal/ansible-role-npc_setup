#! /bin/bash

SETUP_PLAYBOOK_YAML='---
- hosts: localhost
  gather_facts: no
  roles: 
    - xiaopal.npc_setup
  pre_tasks:
    - include_vars: setup-vars.yml'

do_playbook(){
	local NPC_SETUP_TMP="$(mktemp -d)" && trap "rm -fr '$NPC_SETUP_TMP'" EXIT
	local STDIN="$NPC_SETUP_TMP/stdin.yml" \
		SETUP_VARS="$NPC_SETUP_TMP/setup-vars.yml" \
		SETUP_PLAYBOOK="$NPC_SETUP_TMP/setup.yml"
	local ARGS=() ARG
	while ARG="$1" && shift; do
		case "$ARG" in
		--stdin|-)
			cat>"$STDIN" && ARGS=("${ARGS[@]}" "$STDIN") || return 1
			;;
		--setup)
			local VARS="${1:--}" && shift
			[ "$VARS" = '-' ] && cat>"$SETUP_VARS" || {
				[ -f "$VARS" ] && cat "$VARS">"$SETUP_VARS" || return 1
			}
			echo "$SETUP_PLAYBOOK_YAML">"$SETUP_PLAYBOOK" && ARGS=("${ARGS[@]}" "$SETUP_PLAYBOOK")
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
