#! /bin/bash

setup_resources "volumes"

FILTER_LOAD_VOLUME='{
		name: .name,
		id: .id,
		actual_capacity: "\(.size)G",
		available: (.status != "mount_succ"),
		volume_uuid: .volume_uuid,
		instance_id: (if .status == "mount_succ" then .service_name else null end)
	}'

load_volumes(){
	local LIMIT=20 OFFSET=0
	while (( LIMIT > 0 )); do
		local PARAMS="limit=$LIMIT&offset=$OFFSET" && LIMIT=0
		while read -r VOLUME_ENTRY; do
			LIMIT=20 && jq -c "select(.)|$FILTER_LOAD_VOLUME"<<<"$VOLUME_ENTRY"
		done < <(npc api 'json.volumes[]' GET "/api/v1/cloud-volumes?$PARAMS") 
		(( OFFSET += LIMIT ))
	done | jq -sc '.'
}

init_volumes(){
	local INPUT="$1" STAGE="$2"
	jq_check '.npc_volumes|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '.npc_volumes//[]' $INPUT || >>$STAGE.error) \
			<(load_volumes || >>$STAGE.error) \
			'. + (if .update then {update: false}
					+ if  .capacity and (.capacity|sub("[Gg]$"; "")) != (.actual_capacity|sub("[Gg]$"; "")) then
						{update: true}
					else {} end
				else {} end)' || return 1
	}
	return 0
}

api_create_volume(){
	local CREATE_VOLUME="$1"
	(
		exec 100>$NPC_STAGE/volumes.create_lock && flock 100
		local RESPONSE="$(checked_api . POST "/api/v1/cloud-volumes" "$CREATE_VOLUME")" \
			&& echo "$RESPONSE" \
			&& [ ! -z "$RESPONSE" ]  \
			&& local VOLUME_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" \
			&& [ ! -z "$VOLUME_ID" ] \
			&& sleep 0.2s || echo "[ERROR] ${RESPONSE:-No response}" >&2
	)
}

volumes_create(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	local CREATE_VOLUME="$(jq -c '{
		volume_name: .name,
		az_name: (.zone//.az),
		type: .type,
		format:(.format//"Raw"),
		size: (.capacity|sub("[Gg]$"; "")|tonumber)
	}|with_entries(select(.value))'<<<"$VOLUME")"
	while true; do
		local RESPONSE="$(api_create_volume "$CREATE_VOLUME")" && [ ! -z "$RESPONSE" ] \
			&& local VOLUME_ID="$(jq -r '.id//empty' <<<"$RESPONSE")" && [ ! -z "$VOLUME_ID" ] \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" && {
				echo "[INFO] volume '$VOLUME_ID' created." >&2
				return 0
			}
		# {"code":4030001,"msg":"Api freq out of limit."}
		[ "$(jq -r .code <<<"$RESPONSE")" = "4030001" ] && (
			exec 100>$NPC_STAGE/volumes.retries && flock 100 \
				&& action_sleep "$NPC_ACTION_RETRY_SECONDS" "$CTX" ) && continue
		return 1
	done
}

volumes_update(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	local VOLUME_ID="$(jq -r .id<<<"$VOLUME")" && [ ! -z "$VOLUME_ID" ] || return 1
	local SIZE="$(jq -r '.capacity|sub("[Gg]$"; "")|tonumber'<<<"$VOLUME")" MOUNT_INSTANCE_ID MOUNT_VOLUME_UUID 
	jq_check '.available'<<<"$VOLUME" || {
		MOUNT_INSTANCE_ID="$(jq -r '.instance_id'<<<"$VOLUME")"
		MOUNT_VOLUME_UUID="$(jq -r '.volume_uuid'<<<"$VOLUME")"
		unmount_instance_volume "$MOUNT_INSTANCE_ID" "$MOUNT_VOLUME_UUID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	checked_api '{code:status}' '.' PUT "/api/v1/cloud-volumes/$VOLUME_ID/actions/resize?size=$SIZE" >/dev/null \
		&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	[ ! -z "$MOUNT_INSTANCE_ID" ] && {
		mount_instance_volume "$MOUNT_INSTANCE_ID" "$MOUNT_VOLUME_UUID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	echo "[INFO] volume '$VOLUME_ID' updated." >&2
	return 0
}

volumes_destroy(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	local VOLUME_ID="$(jq -r .id<<<"$VOLUME")" && [ ! -z "$VOLUME_ID" ] || return 1
	jq_check '.available'<<<"$VOLUME" || {
		local MOUNT_INSTANCE_ID="$(jq -r '.instance_id'<<<"$VOLUME")" \
			MOUNT_VOLUME_UUID="$(jq -r '.volume_uuid'<<<"$VOLUME")" 
		unmount_instance_volume "$MOUNT_INSTANCE_ID" "$MOUNT_VOLUME_UUID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	checked_api '{code:status}' '.' DELETE "/api/v1/cloud-volumes/$VOLUME_ID" >/dev/null && {
		echo "[INFO] volume '$VOLUME_ID' destroyed." >&2
		return 0
	}
	return 1
}

volumes_wait_status(){
	local VOLUME_ID="$1" CTX="$2" FILTER="$3" && [ ! -z "$VOLUME_ID" ] || return 1
	while action_check_continue "$CTX"; do
		if [ ! -z "$FILTER" ]; then
			OPTION_SILENCE=Y checked_api 'if .status|endswith("ing")|not then ('"$FILTER_LOAD_VOLUME|$FILTER"') else empty end' GET "/api/v1/cloud-volumes/$VOLUME_ID" && return 0
		else
			OPTION_SILENCE=Y checked_api '.status|endswith("ing")|not' GET "/api/v1/cloud-volumes/$VOLUME_ID" >/dev/null && return 0
		fi
		sleep "$NPC_ACTION_PULL_SECONDS"
	done
	return 1
}

volumes_lookup(){
	local VOLUME_NAME="$1" FILTER="$2" STAGE="$NPC_STAGE/volumes.lookup"
	( exec 100>$STAGE.lock && flock 100
		[ ! -f $STAGE ] && {
			load_volumes >$STAGE || rm -f $STAGE
		}
	)
	[ -f $STAGE ] && VOLUME_NAME="$VOLUME_NAME" \
		jq_check --stdout ".[]|select(.name==env.VOLUME_NAME)${FILTER:+|$FILTER}" $STAGE	\
		&& return 0
	echo "[ERROR] volume '$VOLUME_NAME' not found" >&2
	return 1
}

mount_instance_volume(){
	local INSTANCE_ID="$1" VOLUME_UUID="$2"
	checked_api PUT "/api/v1/vm/$INSTANCE_ID/action/mount_volume/$VOLUME_UUID"
	# TODO: handle {"code":"4000797","msg":"Please retry."}	
}

unmount_instance_volume(){
	local INSTANCE_ID="$1" VOLUME_UUID="$2"
	checked_api DELETE "/api/v1/vm/$INSTANCE_ID/action/unmount_volume/$VOLUME_UUID"
	# TODO: handle {"code":"4000797","msg":"Please retry."}
}

volumes_mount(){
	local INSTANCE_ID="$1" VOLUME_NAME="$2" CTX="$3" WAIT_INSTANCE="$4" \
		&& [ ! -z "$INSTANCE_ID" ] && [ ! -z "$VOLUME_NAME" ] || return 1
	local VOLUME_ID="$(volumes_lookup "$VOLUME_NAME" '.id')" && [ ! -z "$VOLUME_ID" ] || return 1
	local VOLUME="$(volumes_wait_status "$VOLUME_ID" "$CTX" '.')" && [ ! -z "$VOLUME" ] || return 1
	local MOUNT_INSTANCE_ID="$(jq -r '.instance_id'<<<"$VOLUME")" \
		MOUNT_VOLUME_UUID="$(jq -r '.volume_uuid'<<<"$VOLUME")"
	jq_check '.available'<<<"$VOLUME" || {
		unmount_instance_volume "$MOUNT_INSTANCE_ID" "$MOUNT_VOLUME_UUID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	while true; do
		local RESPONSE="$(npc api --error PUT "/api/v1/vm/$INSTANCE_ID/action/mount_volume/$MOUNT_VOLUME_UUID")"
		[ "$(jq -r .code <<<"$RESPONSE")" = "200" ] \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" && return 0

		echo "[ERROR] ${RESPONSE:-No response}" >&2

		# {"code":"4000720","msg":"instance status error."}
		[ ! -z "$WAIT_INSTANCE" ] && [ "$(jq -r .code <<<"$RESPONSE")" = "4000720" ] && {
			action_sleep "$NPC_ACTION_RETRY_SECONDS" "$CTX" && continue
		}

		return 1
	done
}

volumes_unmount(){
	local INSTANCE_ID="$1" VOLUME_NAME="$2" CTX="$3" && [ ! -z "$INSTANCE_ID" ] && [ ! -z "$VOLUME_NAME" ] || return 1
	local VOLUME_ID="$(volumes_lookup "$VOLUME_NAME" '.id')" && [ ! -z "$VOLUME_ID" ] || return 1
	local VOLUME="$(volumes_wait_status "$VOLUME_ID" "$CTX" '.')" && [ ! -z "$VOLUME" ] || return 1
	INSTANCE_ID="$INSTANCE_ID" jq_check '.instance_id == env.INSTANCE_ID'<<<"$VOLUME" && {
		local MOUNT_VOLUME_UUID="$(jq -r '.volume_uuid'<<<"$VOLUME")" 
		unmount_instance_volume "$INSTANCE_ID" "$MOUNT_VOLUME_UUID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	return 0
}

report_filters 'if .instances and .volumes then 
		(.volumes as $volumes | .instances |= map_values(
			if .volumes then 
				(.volumes |= map_values(($volumes[.name]//{}) + .)) 
			else . end 
		)) 
	else . end'