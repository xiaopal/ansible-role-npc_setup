#! /bin/bash

NPC_STAGE="$(pwd)/.npc-setup"
NPC_ACTION_FORKS=${NPC_ACTION_FORKS:-5}
NPC_ACTION_TIMEOUT=${NPC_ACTION_TIMEOUT:-5m}
NPC_ACTION_PULL_SECONDS=${NPC_ACTION_PULL_SECONDS:-1}
NPC_ACTION_RETRY_SECONDS=${NPC_ACTION_RETRY_SECONDS:-5}

do_setup(){
	local ARG INPUT='{}' ACTIONS ACTION_INIT ACTION_SUSPEND ACTION_RESUME ACTION_RESTART ACTION_INIT_SSH_KEY ACTION_OMIT_ABSENT ACTION_FILTER_BY_SSH_KEY
	while ARG="$1" && shift; do
		[ ! -z "$ARG" ] && case "$ARG" in
			--create|--update|--destroy)
				ACTIONS="${ACTIONS} ${ARG#--}"
				;;
			--omit-absent)
				ACTION_OMIT_ABSENT='Y'
				;;
			--filter-by-ssh-key)
				ACTION_FILTER_BY_SSH_KEY='Y'
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
	[ ! -z "$ACTION_RESUME" ] || export ACTION_OMIT_ABSENT ACTION_FILTER_BY_SSH_KEY

	for RESOURCE in "${NPC_SETUP_RESOURCES[@]}"; do
		[ ! -z "$ACTION_RESUME" ] || {
			"init_$RESOURCE" "$NPC_STAGE/.input" "$NPC_STAGE/$RESOURCE" || return 1
		}
	
		[ ! -z "$ACTION_INIT" ] || for ACTION in ${ACTIONS:-create update destroy}; do
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

report(){
	report_resources(){
		local RESOURCE="$1" STAGE="$NPC_STAGE/$1"
		local RESOURCE_FILTER="{$RESOURCE:([{key:.name,value:.}]|from_entries)}"
		[ -f $STAGE ] && {
			jq -nc "{ $RESOURCE:{} }"
			jq -c ".[]|select(.actual_present and (.create or .update or .destroy or .absent | not))|$RESOURCE_FILTER" $STAGE		
			[ -f $STAGE.creating ] && if [ ! -f $STAGE.created ]; then
				jq -c '{creating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.creating
			else
				jq -c '.+{change_action:"created"}|'"$RESOURCE_FILTER" $STAGE.created
				jq -c '{created: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.created
			fi
			[ -f $STAGE.updating ] && if [ ! -f $STAGE.updated ]; then
				jq -c '.+{change_action:"updating"}|'"$RESOURCE_FILTER" $STAGE.updating
				jq -c '{updating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updating
			else
				jq -c '.+{change_action:"updated"}|'"$RESOURCE_FILTER" $STAGE.updated
				jq -c '{updated: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updated
			fi
			[ -f $STAGE.destroying ] && if [ ! -f $STAGE.destroyed ]; then
				jq -c '.+{change_action:"destroying"}|'"$RESOURCE_FILTER" $STAGE.destroying
				jq -c '{destroying: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroying
			else
				jq -c '{destroyed: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroyed
			fi
			# [ -f $STAGE.omit ] && jq -c '.+{change_action:"omit"}|'"{$RESOURCE:[.]}" $STAGE.omit
		}
	}
	
	local REDUCE_FILTER
	for RESOURCE in "${NPC_SETUP_RESOURCES[@]}"; do
		REDUCE_FILTER="$REDUCE_FILTER $RESOURCE: (if \$item.$RESOURCE then ((.$RESOURCE//{}) + \$item.$RESOURCE) else .$RESOURCE end),"
	done
	{
		for RESOURCE in "${NPC_SETUP_RESOURCES[@]}"; do
			report_resources "$RESOURCE"
		done
		return 0	
	} | jq -sc 'reduce .[] as $item ( {}; {
			'"$REDUCE_FILTER"'
			creating: (if $item.creating then ((.creating//[]) + $item.creating) else .creating end),
			updating: (if $item.updating then ((.updating//[]) + $item.updating) else .updating end),
			destroying: (if $item.destroying then ((.destroying//[]) + $item.destroying) else .destroying end),
			created: (if $item.created then ((.created//[]) + $item.created) else .created end),
			updated: (if $item.updated then ((.updated//[]) + $item.updated) else .updated end),
			destroyed: (if $item.destroyed then ((.destroyed//[]) + $item.destroyed) else .destroyed end)
		} | with_entries(select(.value))) | . + { 
			changing: (.creating or .updating or .destroying), 
			changed: (.created or .updated or .destroyed)
		}'
}


SCRIPT="${BASH_SOURCE[0]}" && [ -L "$SCRIPT" ] && SCRIPT="$(readlink -f "$SCRIPT")"
SCRIPT_DIR="$(cd "$(dirname $SCRIPT)"; pwd)" 
. $SCRIPT_DIR/npc-setup.ctx.sh \
	&& . $SCRIPT_DIR/npc-setup.ssh_key.sh \
	&& . $SCRIPT_DIR/npc-setup.volume.sh \
	&& . $SCRIPT_DIR/npc-setup.instance.sh \
	&& do_setup "$@"
