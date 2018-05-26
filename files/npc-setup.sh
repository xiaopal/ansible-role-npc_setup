#! /bin/bash

NPC_STAGE="$(pwd)/.npc-setup"
NPC_ACTION_FORKS=${NPC_ACTION_FORKS:-5}
NPC_ACTION_TIMEOUT=${NPC_ACTION_TIMEOUT:-5m}
NPC_ACTION_PULL_SECONDS=${NPC_ACTION_PULL_SECONDS:-1}
NPC_ACTION_RETRY_SECONDS=${NPC_ACTION_RETRY_SECONDS:-5}

do_setup(){
	local ARG INPUT='{}' ACTIONS ACTION_INIT ACTION_SUSPEND ACTION_RESUME ACTION_RESTART ACTION_INIT_SSH_KEY
	while ARG="$1" && shift; do
		[ ! -z "$ARG" ] && case "$ARG" in
			--create|--update|--destroy)
				ACTIONS="${ACTIONS} ${ARG#--}"
				;;
			--filter-by-ssh-key)
				:
				;;
			--omit-absent)
				:
				;;
			--init|--setup)
				ACTION_INIT='Y'
				;;
			--suspend)
				ACTION_SUSPEND='Y'
				;;
			--resume)
				ACTION_RESUME='Y'
				;;
			--restart)
				ACTION_RESTART='Y'
				;;
			--init-ssh-key)
				ACTION_INIT_SSH_KEY='Y'
				;;
			--|-)
				INPUT="$(jq -c --argjson input "$INPUT" '$input + .')"
				[ -z "$INPUT" ] && {
					echo "[ERROR] cannot parse stdin" >&2
					exit 1
				}
				;;
			@*)
				INPUT="$(jq -c --argjson input "$INPUT" '$input + .' "${ARG#@}")"
				[ -z "$INPUT" ] && {
					echo "[ERROR] cannot parse file: '${ARG#@}'" >&2
					exit 1
				}
				;;
			*)
				INPUT="$(jq -c --argjson input "$INPUT" '$input + .'<<<"$ARG")"
				[ -z "$INPUT" ] && {
					echo "[ERROR] cannot parse json: '${ARG}'" >&2
					exit 1
				}
				;;
			esac
	done
	
	mkdir -p "$NPC_STAGE" && cd "$NPC_STAGE" ; trap "wait; rm -fr '$NPC_STAGE'" EXIT
	exec 99<$NPC_STAGE && flock 99 || return 1
	[ -f $NPC_STAGE/.input ] && {
		[ ! -z "$ACTION_RESTART" ] && rm -f $NPC_STAGE/.input || {
			[ ! -z "$ACTION_RESUME" ] || {
				echo "[ERROR] $NPC_STAGE/.input already exists" >&2
				return 1
			}
		}
	}
	[ ! -f $NPC_STAGE/.input ] && {
		[ ! -z "$ACTION_RESUME" ] && {
			echo "[ERROR] $NPC_STAGE/.input not exists" >&2
			return 1
		}
		jq -c '.'<<<"$INPUT" >$NPC_STAGE/.input || return 1
	}

	echo "[INFO] init" >&2
	local NPC_SSH_KEY="$(jq -r 'select(.npc_ssh_key)|.npc_ssh_key.name//empty' $NPC_STAGE/.input)" NPC_SSH_KEY_FILE
	[ ! -z "$ACTION_INIT_SSH_KEY" ] && {
		[ ! -z "$NPC_SSH_KEY" ] || {
			echo "[ERROR] npc_ssh_key not defined." >&2
			return 1
		}
		check_ssh_keys --create <<<"$NPC_SSH_KEY" || return 1
	}
	[ ! -z "$NPC_SSH_KEY" ] && NPC_SSH_KEY_FILE="$(cd ~; pwd)/.npc/ssh_key.$NPC_SSH_KEY" && [ -f "$NPC_SSH_KEY_FILE" ] || NPC_SSH_KEY_FILE=
	export NPC_SSH_KEY NPC_SSH_KEY_FILE

	for RESOURCE in "${NPC_SETUP_RESOURCES[@]}"; do
		[ ! -z "$ACTION_RESUME" ] || {
			"init_$RESOURCE" "$NPC_STAGE/.input" "$NPC_STAGE/$RESOURCE" || return 1
		}
	
		[ ! -z "$ACTION_INIT" ] || for ACTION in ${ACTIONS:-destroy update create}; do
			[ ! -z "$ACTION" ] && {
				echo "[INFO] $ACTION $RESOURCE">&2
				[ "$ACTION" = "create" ] && {
					apply_actions "${RESOURCE}_create" "$NPC_STAGE/$RESOURCE.creating" "$NPC_STAGE/$RESOURCE.created" || return 1
				}
				[ "$ACTION" = "update" ] && {
					apply_actions "${RESOURCE}_update" "$NPC_STAGE/$RESOURCE.updating" "$NPC_STAGE/$RESOURCE.updated" || return 1
				}
				[ "$ACTION" = "destroy" ] && {
					apply_actions "${RESOURCE}_destroy" "$NPC_STAGE/$RESOURCE.destroying" "$NPC_STAGE/$RESOURCE.destroyed" || return 1
				}
				
			}
		done
	done
	echo "[INFO] finish">&2
	report || return 1
	[ ! -z "$ACTION_SUSPEND" ] && trap - EXIT
	return 0
}


NPC_SETUP_RESOURCES=()
setup_resources(){
	NPC_SETUP_RESOURCES=("${NPC_SETUP_RESOURCES[@]}" "$@")
}

NPC_REPORT_FILTERS=
report_filters(){
	NPC_REPORT_FILTERS="$NPC_REPORT_FILTERS | $*"
}

report(){
	report_resources --summary --report "$NPC_REPORT_FILTERS" "${NPC_SETUP_RESOURCES[@]}"
}

SCRIPT="${BASH_SOURCE[0]}" && [ -L "$SCRIPT" ] && SCRIPT="$(readlink -f "$SCRIPT")"
SCRIPT_DIR="$(cd "$(dirname $SCRIPT)"; pwd)" 
. $SCRIPT_DIR/npc-setup.ctx.sh \
	&& . $SCRIPT_DIR/npc-setup.ssh_key.sh \
	&& . $SCRIPT_DIR/npc-setup.instance_type.sh \
	&& . $SCRIPT_DIR/npc-setup.image.sh \
	&& . $SCRIPT_DIR/npc-setup.vpc.sh \
	&& . $SCRIPT_DIR/npc-setup.dns_zone.sh \
	&& . $SCRIPT_DIR/npc-setup.volume.sh \
	&& . $SCRIPT_DIR/npc-setup.instance.sh \
	&& . $SCRIPT_DIR/npc-setup.vpc_route.sh \
	&& . $SCRIPT_DIR/npc-setup.dns_record_set.sh \
	&& do_setup "$@"
