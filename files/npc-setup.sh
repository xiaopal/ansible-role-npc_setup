#! /bin/bash

NPC_STAGE="$(pwd)/.npc-setup"
NPC_ACTION_FORKS=${NPC_ACTION_FORKS:-5}
NPC_ACTION_TIMEOUT=${NPC_ACTION_TIMEOUT:-5m}
NPC_ACTION_PULL_SECONDS=${NPC_ACTION_PULL_SECONDS:-5}
NPC_ACTION_RETRY_SECONDS=${NPC_ACTION_RETRY_SECONDS:-10}

do_setup(){
	local ARG INPUT='{}' ACTIONS ACTION_INIT ACTION_SUSPEND ACTION_RESUME ACTION_RESTART ACTION_INIT_SSH_KEY
	while ARG="$1" && shift; do
		[ ! -z "$ARG" ] && case "$ARG" in
			--create|--update|--destroy|-create|-update|-destroy)
				ACTIONS="${ACTIONS} ${ARG#--}"
				;;
			--init|--setup|-init|-setup)
				ACTION_INIT='Y'
				;;
			--suspend|-suspend)
				ACTION_SUSPEND='Y'
				;;
			--resume|-resume)
				ACTION_RESUME='Y'
				;;
			--restart|-restart)
				ACTION_RESTART='Y'
				;;
			--init-ssh-key|-init-ssh-key)
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

	local NPC_SSH_KEY="$(jq -r '.npc_ssh_key.name//"ansible"' $NPC_STAGE/.input)"
	local NPC_SSH_KEY_FILE="$(cd ~; pwd)/.npc/ssh_key.$NPC_SSH_KEY" && [ -f "$NPC_SSH_KEY_FILE" ] || NPC_SSH_KEY_FILE=
	export NPC_SSH_KEY NPC_SSH_KEY_FILE
	echo "[INFO] init" >&2
	[ ! -z "$ACTION_INIT_SSH_KEY" ] && {
		check_ssh_keys --create <<<"$NPC_SSH_KEY" || return 1
	}
	init || return 1
	[ ! -z "$ACTION_INIT" ] || for ACTION in ${ACTIONS:-create update destroy}; do
		[ ! -z "$ACTION" ] && {
			echo "[INFO] $ACTION instances">&2
			"$ACTION" || return 1
		}
	done
	echo "[INFO] finish">&2
	report || return 1
	[ ! -z "$ACTION_SUSPEND" ] && trap - EXIT
	return 0
}

MAPPER_LOAD_INSTANCE='{
		id: .uuid,
		name: .name,
		status: .status,
		lan_ip: .vnet_ip,
		actual_image: .images[0].imageName,
		actual_type: { cpu:.vcpu, memory:"\(.memory_gb)G"}
	}'
FILTER_LOAD_INSTANCE='.status=="ACTIVE" and .lan_ip'
init(){
	local INPUT="$NPC_STAGE/.input"
	jq -ce '.npc_instances | arrays' $INPUT >$NPC_STAGE/instances.tmp && {
		while read -r LINE; do
			for NAME in $(eval "echo $(jq -r '.name'<<<"$LINE")"); do
				[ ! -z "$NAME" ] && NAME="$NAME" jq -c '. + {name:env.NAME}'<<<"$LINE"
			done
		done < <(jq -c '.[]' $NPC_STAGE/instances.tmp ) \
			| jq --argjson input "$(jq -c . $INPUT)" -sc 'map({key:.name, value:(.+{
					default_instance_image: $input.npc_instance_image,
					default_instance_type: $input.npc_instance_type,
					ssh_keys: ((.ssh_keys//[]) + [env.NPC_SSH_KEY] | unique)
				})})|from_entries' >$NPC_STAGE/instances.expected || return 1
		npc api 'json.instances | map(
			select(try .properties|fromjson["publicKeys"]|split(",")|contains([env.NPC_SSH_KEY]))
				|'"$MAPPER_LOAD_INSTANCE"'
				|{
					key: .name,
					value: .
				})|from_entries' GET '/api/v1/vm/allInstanceInfo?pageSize=9999&pageNum=1' >$NPC_STAGE/instances.actual \
		|| return 1

		jq -re ".[]|select($FILTER_LOAD_INSTANCE|not)"'
			|"[ERROR] instance=\(.name), status=\(.name), lan_ip=\(.lan_ip)"' $NPC_STAGE/instances.actual >&2 && return 1

		jq -sce '(.[0] | map_values(. + {
					defined: true,
					attached: false
				})) * (.[1] | map_values(. + {
					attached: true
				})) 
			| map_values(. + {
				groups: ( .groups//[] | unique ),
				'"${NPC_SSH_KEY_FILE:+ssh_key_file: env.NPC_SSH_KEY_FILE,}"'
				create: (.defined and (.attached|not)),
				update: (.defined and .attached 
					and ( (.instance_type and .actual_type != .instance_type) 
						or (.instance_image and .actual_image != .instance_image ) )
				),
				destroy : ((.defined|not) and .attached)
			})' $NPC_STAGE/instances.expected $NPC_STAGE/instances.actual >$NPC_STAGE/instances \
			&& rm -f $NPC_STAGE/instances.* || return 1
		jq -ce '.[]|select(.create)' $NPC_STAGE/instances > $NPC_STAGE/instances.creating || rm -f $NPC_STAGE/instances.creating
		jq -ce '.[]|select(.update)' $NPC_STAGE/instances > $NPC_STAGE/instances.updating || rm -f $NPC_STAGE/instances.updating
		jq -ce '.[]|select(.destroy)' $NPC_STAGE/instances > $NPC_STAGE/instances.destroying || rm -f $NPC_STAGE/instances.destroying
	}; rm -f $NPC_STAGE/instances.tmp
}

ssh_key_fingerprint(){
	local KEY_FILE="$1" && [ -f "$KEY_FILE" ] \
		&& read _ FINGERPRINT _<<<"$(ssh-keygen -lE md5 -f "$KEY_FILE")" \
		&& echo "${FINGERPRINT#MD5:}"
}

check_ssh_keys(){
	local STAGE="$NPC_STAGE/ssh_keys" FORCE_CREATE CHECK_FILE
	while ARG="$1" && shift; do
		case "$ARG" in
			--check-file)
				CHECK_FILE=Y
				;;
			--create)
				FORCE_CREATE=Y
				CHECK_FILE=Y
				;;
		esac
	done
	while read -r SSH_KEY; do
		( exec 100>$STAGE.lock && flock 100
			[ -f $STAGE ] || {
				npc api 'json|arrays|map({key:.name, value:.})|from_entries' \
					GET "/api/v1/secret-keys" >$STAGE || { rm -f $STAGE; exit 1; }				
			}
			local STAGE_SSH_KEY="$(jq -c --arg ssh_key "$SSH_KEY" '.[$ssh_key]//empty' $STAGE)" \
				SSH_KEY_FILE="$(cd ~; pwd)/.npc/ssh_key.$SSH_KEY"
			[ ! -z "$STAGE_SSH_KEY" ] && {
				[ ! -z "$CHECK_FILE" ] || exit 0
				[ -f "$SSH_KEY_FILE" ] \
					&& [ "$(ssh_key_fingerprint "$SSH_KEY_FILE")" = "$(jq -r '.fingerprint'<<<"$STAGE_SSH_KEY")" ] \
					&& exit 0
			}
			[ -f "$SSH_KEY_FILE" ] && {
				[ ! -z "$STAGE_SSH_KEY" ] && {
					echo "[ERROR] ssh_key '$SSH_KEY' fingerprint mismatch" >&2
					exit 1
				}
				echo "[ERROR] '$SSH_KEY_FILE' already exists" >&2
				exit 1
			}
			local SSH_KEY_ID
			[ ! -z "$STAGE_SSH_KEY" ] && SSH_KEY_ID="$(jq -r '.id'<<<"$STAGE_SSH_KEY")" || {
				echo "[ERROR] ssh_key '$SSH_KEY' not found" >&2
				[ ! -z "$FORCE_CREATE" ] && {
					rm -f $STAGE && mkdir -p "$(dirname "$SSH_KEY_FILE")"
					STAGE_SSH_KEY="$(npc api 'json|select(.id and .fingerprint)' \
						POST /api/v1/secret-keys "$(jq -Rc "{key_name:.}"<<<"$SSH_KEY")")"
					[ ! -z "$STAGE_SSH_KEY" ] && SSH_KEY_ID="$(jq -r '.id'<<<"$STAGE_SSH_KEY")" || {
						echo "[ERROR] Failed to create ssh_key '$SSH_KEY'" >&2
					}
				}
			}
			[ ! -z "$SSH_KEY_ID" ] && [ ! -z "$FORCE_CREATE" ] && {
				npc api GET "/api/v1/secret-keys/$SSH_KEY_ID" >$SSH_KEY_FILE \
					&& chmod 600 $SSH_KEY_FILE \
					&& [ "$(ssh_key_fingerprint "$SSH_KEY_FILE")" = "$(jq -r '.fingerprint'<<<"$STAGE_SSH_KEY")" ] \
					&& exit 0
				rm -f $SSH_KEY_FILE
				echo "[ERROR] Failed to download ssh_key '$SSH_KEY'" >&2
			} 
			echo "[ERROR] '$SSH_KEY_FILE' not exists" >&2
			exit 1			
		) || return 1
	done
	return 0
}

report(){
	{
		[ -f $NPC_STAGE/instances ] && {
			jq -nc '{ instances:[] }'
			jq -c '.[]|select(.create or .update or .destroy | not)|{instances:[.]}' $NPC_STAGE/instances		
			[ -f $NPC_STAGE/instances.creating ] && if [ ! -f $NPC_STAGE/instances.created ]; then
				jq -c '{creating: [{instance:.}]}' $NPC_STAGE/instances.creating
			else
				jq -c '.+{change_action:"created"}|{instances:[.]}' $NPC_STAGE/instances.created
				jq -c '{created: [{instance:.}]}' $NPC_STAGE/instances.created
			fi
			[ -f $NPC_STAGE/instances.updating ] && if [ ! -f $NPC_STAGE/instances.updated ]; then
				jq -c '.+{change_action:"updating"}|{instances:[.]}' $NPC_STAGE/instances.updating
				jq -c '{updating: [{instance:.}]}' $NPC_STAGE/instances.updating
			else
				jq -c '.+{change_action:"updated"}|{instances:[.]}' $NPC_STAGE/instances.updated
				jq -c '{updated: [{instance:.}]}' $NPC_STAGE/instances.updated
			fi
			[ -f $NPC_STAGE/instances.destroying ] && if [ ! -f $NPC_STAGE/instances.destroyed ]; then
				jq -c '.+{change_action:"destroying"}|{instances:[.]}' $NPC_STAGE/instances.destroying
				jq -c '{destroying: [{instance:.}]}' $NPC_STAGE/instances.destroying
			else
				jq -c '{destroyed: [{instance:.}]}' $NPC_STAGE/instances.destroyed
			fi
		}
	} | jq -sc 'reduce .[] as $item ( {}; {
			instances: (if $item.instances then ((.instances//[]) + $item.instances) else .instances end),
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

action_loop(){
	local INPUT="$1" ACTION="$2" RESULT="$3" FORK=0 && [ -f $INPUT ] || return 0
	do_wait(){
		wait && [ -f $RESULT ] || return 1
		for I in $(seq 0 "$((FORK-1))"); do
			[ -f $RESULT.$I ] && jq -ce '.' $RESULT.$I >> $RESULT || {
				rm -f $RESULT
				return 1
			}
		done
	}
	touch $RESULT && while read -r INSTANCE; do
		rm -f $RESULT.$FORK && touch $RESULT
		{ $ACTION "$RESULT.$FORK" "$INSTANCE" "$SECONDS $RESULT" || rm -f $RESULT; }&
		((++FORK >= ${NPC_ACTION_FORKS:-1})) && {
			do_wait || return 1
			FORK=0
		}
	done <$INPUT
	do_wait || return 1
	rm -f $RESULT.*
	return 0
}

action_check_continue(){
	local START RESULT TIMEOUT="${2:-$NPC_ACTION_TIMEOUT}"
	read -r START RESULT _<<<"$1"|| return 1
	[[ "$TIMEOUT" = *s ]] && TIMEOUT="${TIMEOUT%s}"
	[[ "$TIMEOUT" = *m ]] && TIMEOUT="${TIMEOUT%m}" && ((TIMEOUT *= 60))
	(( SECONDS - START < TIMEOUT )) || {
		echo "[ERROR] timeout" >&2
		return 1
	}
	[ ! -f $RESULT ] && {
		echo "[ERROR] cancel" >&2
		return 1
	}
	return 0
}

create(){
	action_loop "$NPC_STAGE/instances.creating" create_instance "$NPC_STAGE/instances.created" \
		&& return 0 || return 1
}

update(){
	action_loop "$NPC_STAGE/instances.updating" update_instance "$NPC_STAGE/instances.updated" \
		&& return 0 || return 1
}

destroy(){
	action_loop "$NPC_STAGE/instances.destroying" destroy_instance "$NPC_STAGE/instances.destroyed" \
		&& return 0 || return 1
}

lookup_image(){
	local IMAGE_NAME="$1"
	for	IMAGE_TYPE in "privateimages" "publicimages"; do
		local STAGE="$NPC_STAGE/$IMAGE_TYPE"
		( exec 100>$STAGE.lock && flock 100
			[ ! -f $STAGE ] && {
				npc api 'json.images' GET "/api/v1/vm/$IMAGE_TYPE?pageSize=9999&pageNum=1&keyword=" >$STAGE || rm -f $STAGE
			}
		)
		[ -f $STAGE ] && IMAGE_NAME="$IMAGE_NAME" \
			jq -re '.[]|select(.imageName==env.IMAGE_NAME or .imageId==env.IMAGE_NAME)|.imageId' $STAGE	\
			&& return 0
	done
	return 1
}

prepare_to_create(){
	local INSTANCE="$1"
	local IMAGE_NAME="$(jq -r '.instance_image//.default_instance_image//empty'<<<"$INSTANCE")" IMAGE_ID
	[ ! -z "$IMAGE_NAME" ] && IMAGE_ID="$(lookup_image "$IMAGE_NAME")" && [ ! -z "$IMAGE_ID" ] || {
		echo "[ERROR] instance_image - '$IMAGE_NAME' not found" >&2
		return 1
	}

	jq -r '.ssh_keys//empty|.[]'<<<"$INSTANCE" | check_ssh_keys || return 1

	IMAGE_ID="$IMAGE_ID" \
	jq -c '. + {
		image_id: env.IMAGE_ID,
		cpu_weight: (.instance_type.cpu//.default_instance_type.cpu//2),
		memory_weight: ((.instance_type.memory//.default_instance_type.memory//"4G")|sub("[Gg]$"; "")|tonumber),
		ssd_weight: 20,
		description:"groups:\(.groups)"
	}'<<<"$INSTANCE" && return 0 || return 1
}

pull_instance_result(){
	local INSTANCE_ID="$1" RESULT="$2" INSTANCE="$3" CTX="$4"
	while action_check_continue "$CTX"; do
		npc api "json|$MAPPER_LOAD_INSTANCE|select($FILTER_LOAD_INSTANCE)" GET "/api/v1/vm/$INSTANCE_ID" >$RESULT.actual \
			&& jq -c --argjson instance "$INSTANCE" '$instance + .' $RESULT.actual >$RESULT && {
				rm -f $RESULT.actual
				return 0
			}
		rm -f $RESULT*; sleep "$NPC_ACTION_PULL_SECONDS"
	done
	return 1
}

create_instance(){
	local RESULT="$1" INSTANCE="$(prepare_to_create "$2")" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	local CREATE_INSTANCE="$(jq -c '{
			bill_info: "HOUR",
			server_info: {
				azCode: (.zone//"A"),
				instance_name: .name,
				ssh_key_names: .ssh_keys,
				image_id: .image_id,
				cpu_weight: .cpu_weight,
				memory_weight: .memory_weight,
				ssd_weight: .ssd_weight,
				description: .description
			}
		}'<<<"$INSTANCE")"
	while true; do
		local RESPONSE="$(npc api --error 'json|((arrays|{id:.[0]})//{})+(objects//{})' \
			POST /api/v1/vm "$CREATE_INSTANCE")"
		[ ! -z "$RESPONSE" ] && local INSTANCE_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" \
			&& [ ! -z "$INSTANCE_ID" ] && pull_instance_result "$INSTANCE_ID" "$RESULT" "$INSTANCE" "$CTX" && {
				echo "[INFO] instace '$INSTANCE_ID' created." >&2
				return 0
			}
		echo "[ERROR] $RESPONSE" >&2
		# {"code":4030001,"msg":"Api freq out of limit."}
		[ "$(jq -r .code <<<"$RESPONSE")" = "4030001" ] || return 1
		( exec 100>$NPC_STAGE/instances.retries && flock 100
			WAIT_SECONDS="$NPC_ACTION_RETRY_SECONDS"
			action_check_continue "$CTX" && while sleep 1s && action_check_continue "$CTX"; do
				(( --WAIT_SECONDS > 0 )) || exit 0
			done; exit 1
		) || return 1
	done
}

update_instance(){
	local RESULT="$1" INSTANCE="$(prepare_to_create "$2")" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	destroy_instance "$RESULT" "$INSTANCE" "$CTX" \
		&& create_instance  "$RESULT" "$INSTANCE" "$CTX" \
		&& return 0 || rm -f $RESULT
	return 1
}

destroy_instance(){
	local RESULT="$1" INSTANCE="$2" CTX="$3"
	local INSTANCE_ID="$(jq -r .id<<<"$INSTANCE")"
	local RESPONSE="$(npc api --error DELETE "/api/v1/vm/$INSTANCE_ID")"
	[ "$(jq -r .code <<<"$RESPONSE")" = "200" ] && jq -c .<<<"$INSTANCE" >$RESULT && {
		echo "[INFO] instace '$INSTANCE_ID' destroyed." >&2
		return 0
	}
	rm -f $RESULT && echo "[ERROR] $RESPONSE" >&2
	return 1
}

do_setup "$@"
