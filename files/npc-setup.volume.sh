#! /bin/bash

setup_resources "volumes"

FILTER_LOAD_VOLUME='{
		name: .DiskName,
		id: .DiskId,
		actual_type: .Type,
		actual_capacity: "\(.Capacity)G",
		available: (.Status != "mount_succ"),
		volume_uuid: .VolumeUUID,
		instance_id: (if .Status == "mount_succ" then .AttachedInstance else null end)
	}'
VOLUME_TYPE_ALIASES='{
  "SSD": "CloudSsd",
  "SAS": "CloudSas",
  "C_SSD": "CloudSsd",
  "C_SAS": "CloudSas",
  "NBS_SSD": "CloudHighPerformanceSsd"
}'

load_volumes(){
	local LIMIT=50 OFFSET=0
	while (( LIMIT > 0 )); do
		local PARAMS="Limit=$LIMIT&Offset=$OFFSET" && LIMIT=0
		while read -r VOLUME_ENTRY; do
			LIMIT=50 && jq -c "select(.)|$FILTER_LOAD_VOLUME"<<<"$VOLUME_ENTRY"
		done < <(npc api2 'json.DiskCxts[]' POST "/ncv?Action=ListDisk&Version=2017-12-28&$PARAMS" '{}')
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
# do not resize			
#					+ if  .capacity and (.capacity|sub("[Gg]$"; "")) != (.actual_capacity|sub("[Gg]$"; "")) then
#						{update: true}
#					else {} end
				else {} end)' || return 1
	}
	return 0
}

volumes_create(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	local VOLUME_ID && VOLUME_ID="$(NPC_API_LOCK="$NPC_STAGE/volumes.create_lock" \
		checked_api2 '.DiskIds[0]//empty' \
		GET "/ncv?Action=CreateDisk&Version=2017-12-28&$(jq -r --argjson aliases "$VOLUME_TYPE_ALIASES" '{
			Scope: (.scope//"NVM"),
			PricingModel: "PostPaid",
			ZoneId: (.zone//.az),
			Name: .name,
			Type: (if .type then $aliases[.type|ascii_upcase]//.type else "CloudSsd" end),
			Capacity: (.capacity|sub("[Gg]$"; "")|tonumber)
		}|to_entries|map(@uri"\(.key)=\(.value)")|join("&")'<<<"$VOLUME")")" && [ ! -z "$VOLUME_ID" ] && {
			echo "[INFO] volume '$VOLUME_ID' created." >&2
			return 0
		}
	return 1
}

volumes_update(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	# resize 已废弃 @ 2019-02-25
	echo "[ERROR] volume resize deprecated." >&2
	return 1
}

volumes_destroy(){
	local VOLUME="$1" RESULT="$2" CTX="$3" && [ ! -z "$VOLUME" ] || return 1
	local VOLUME_ID="$(jq -r .id<<<"$VOLUME")" && [ ! -z "$VOLUME_ID" ] || return 1
	jq_check '.available'<<<"$VOLUME" || {
		local MOUNT_INSTANCE_ID="$(jq -r '.instance_id'<<<"$VOLUME")"
		unmount_instance_volume "$MOUNT_INSTANCE_ID" "$VOLUME_ID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	checked_api2 GET "/ncv?Action=DeleteDisk&Version=2017-12-28&DiskId=$VOLUME_ID" && {
		echo "[INFO] volume '$VOLUME_ID' destroyed." >&2
		return 0
	}
	return 1
}

volumes_wait_status(){
	local VOLUME_ID="$1" CTX="$2" FILTER="$3" && [ ! -z "$VOLUME_ID" ] || return 1
	while action_check_continue "$CTX"; do
		local API2_DESCRIBE=(GET "/ncv?Action=DescribeDisk&Version=2017-12-28&DiskId=$VOLUME_ID")
		if [ ! -z "$FILTER" ]; then
			OPTION_SILENCE=Y checked_api2 '.DiskCxt|if .Status|endswith("ing")|not then ('"$FILTER_LOAD_VOLUME|$FILTER"') else empty end' "${API2_DESCRIBE[@]}" && return 0
		else
			OPTION_SILENCE=Y checked_api2 '.DiskCxt|.Status|endswith("ing")|not' "${API2_DESCRIBE[@]}" >/dev/null && return 0
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
	local INSTANCE_ID="$1" DISK_ID="$2"
	checked_api2 GET "/nvm?Action=AttachDisk&Version=2017-12-14&InstanceId=$INSTANCE_ID&DiskId=$DISK_ID"
}

unmount_instance_volume(){
	local INSTANCE_ID="$1" DISK_ID="$2"
	checked_api2 GET "/nvm?Action=DetachDisk&Version=2017-12-14&InstanceId=$INSTANCE_ID&DiskId=$DISK_ID"
}

volumes_mount(){
	local INSTANCE_ID="$1" VOLUME_NAME="$2" CTX="$3" WAIT_INSTANCE="$4" \
		&& [ ! -z "$INSTANCE_ID" ] && [ ! -z "$VOLUME_NAME" ] || return 1
	local VOLUME_ID="$(volumes_lookup "$VOLUME_NAME" '.id')" && [ ! -z "$VOLUME_ID" ] || return 1
	local VOLUME="$(volumes_wait_status "$VOLUME_ID" "$CTX" '.')" && [ ! -z "$VOLUME" ] || return 1
	local MOUNT_INSTANCE_ID="$(jq -r '.instance_id'<<<"$VOLUME")"
	jq_check '.available'<<<"$VOLUME" || {
		unmount_instance_volume "$MOUNT_INSTANCE_ID" "$VOLUME_ID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	mount_instance_volume "$INSTANCE_ID" "$VOLUME_ID" \
		&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1

	return 0
}

volumes_unmount(){
	local INSTANCE_ID="$1" VOLUME_NAME="$2" CTX="$3" && [ ! -z "$INSTANCE_ID" ] && [ ! -z "$VOLUME_NAME" ] || return 1
	local VOLUME_ID="$(volumes_lookup "$VOLUME_NAME" '.id')" && [ ! -z "$VOLUME_ID" ] || return 1
	local VOLUME="$(volumes_wait_status "$VOLUME_ID" "$CTX" '.')" && [ ! -z "$VOLUME" ] || return 1
	INSTANCE_ID="$INSTANCE_ID" jq_check '.instance_id == env.INSTANCE_ID'<<<"$VOLUME" && {
		unmount_instance_volume "$INSTANCE_ID" "$VOLUME_ID" \
			&& volumes_wait_status "$VOLUME_ID" "$CTX" || return 1
	}
	return 0
}

report_filters 'if .instances and .volumes then 
		(.volumes as $volumes | .instances |= map_values(
			if .volumes then 
				(.volumes |= map_values(($volumes[.name]//{} | del(.present)) + .)) 
			else . end 
		)) 
	else . end'