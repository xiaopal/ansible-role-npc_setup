#! /bin/bash

setup_resources "instances"

MAPPER_LOAD_INSTANCE='{
		id: .uuid,
		name: .name,
		status: .status,
		lan_ip: .vnet_ip,
		actual_image: .images[0].imageName,
		actual_type: { cpu:.vcpu, memory:"\(.memory_gb)G"}
	}'
FILTER_LOAD_INSTANCE='.status=="ACTIVE" and .lan_ip'

init_instances(){
	local INPUT="$1" STAGE="$2"
	jq -ce '.npc_instances|arrays' $INPUT >/dev/null && {
		plan_resources "$STAGE" \
			<(jq -c '. as $input | .npc_instances | map(.+{
					default_instance_image: $input.npc_instance_image,
					default_instance_type: $input.npc_instance_type,
					'"${NPC_SSH_KEY_FILE:+ssh_key_file: env.NPC_SSH_KEY_FILE,}"'
					ssh_keys: ((.ssh_keys//[]) + [env.NPC_SSH_KEY] | unique)
				})' $INPUT || >>$STAGE.error) \
			<(npc api 'json.instances | map(
				select(try .properties|fromjson["publicKeys"]|split(",")|contains([env.NPC_SSH_KEY]))
					|'"$MAPPER_LOAD_INSTANCE"'
					| if '"$FILTER_LOAD_INSTANCE"' then . else error("\(.name): status=\(.name), lan_ip=\(.lan_ip)") end
				)' GET '/api/v1/vm/allInstanceInfo?pageSize=9999&pageNum=1' \
				|| >>$STAGE.error) \
			'(.instance_type and .actual_type != .instance_type) 
				or (.instance_image and .actual_image != .instance_image )' || return 1
	}
	return 0
}

instances_lookup_image(){
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

instances_prepare_to_create(){
	local INSTANCE="$1"
	local IMAGE_NAME="$(jq -r '.instance_image//.default_instance_image//empty'<<<"$INSTANCE")" IMAGE_ID
	[ ! -z "$IMAGE_NAME" ] && IMAGE_ID="$(instances_lookup_image "$IMAGE_NAME")" && [ ! -z "$IMAGE_ID" ] || {
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

instances_pull_result(){
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

instances_create(){
	local RESULT="$1" INSTANCE="$(instances_prepare_to_create "$2")" CTX="$3" && [ -z "$INSTANCE" ] && return 1
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
			&& [ ! -z "$INSTANCE_ID" ] && instances_pull_result "$INSTANCE_ID" "$RESULT" "$INSTANCE" "$CTX" && {
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

instances_update(){
	local RESULT="$1" INSTANCE="$(instances_prepare_to_create "$2")" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	instances_destroy "$RESULT" "$INSTANCE" "$CTX" \
		&& instances_create  "$RESULT" "$INSTANCE" "$CTX" \
		&& return 0 || rm -f $RESULT
	return 1
}

instances_destroy(){
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
