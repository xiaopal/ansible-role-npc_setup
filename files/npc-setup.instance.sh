#! /bin/bash

setup_resources "instances"

MAPPER_LOAD_INSTANCE='{
		id: .uuid,
		name: .name,
		status: .status,
		lan_ip: .vnet_ip,
		actual_wan_ip: (.public_ip//false),
		actual_wan_id: (.public_port_id//false),
		actual_wan_capacity: (if .bandWidth then "\(.bandWidth|tonumber)M" else false end),
		actual_image: .images[0].imageName,
		actual_type: { cpu:.vcpu, memory:"\(.memory_gb)G"}
	}'
FILTER_LOAD_INSTANCE='.status=="ACTIVE" and .lan_ip'

init_instances(){
	local INPUT="$1" STAGE="$2"
	jq_check '.npc_instances|arrays' $INPUT && {
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
			'. + (if .wan_ip then
					if .actual_wan_ip|not then
						{bind_wan_ip:true}
					elif .wan_ip=="new" or .wan_ip==true or .wan_ip=="any" then
						if .wan_capacity and (.wan_capacity|ascii_upcase) != .actual_wan_capacity then 
							{wan_ip: .actual_wan_ip, unbind_wan_ip:true, bind_wan_ip:true, rebind_wan_ip:true}
						else
							{wan_ip: .actual_wan_ip}
						end
					elif .wan_ip != .actual_wan_ip then
						{unbind_wan_ip:true, bind_wan_ip:true}
					else {} end
				elif .wan_ip == false and .actual_wan_ip then
					{unbind_wan_ip:true}
				else {} end) 
			|. + (if .update then {update: false}
					+ if  .instance_type and .actual_type != .instance_type then
						{update: true, recreate: true}
					else {} end
					+ if .instance_image and .actual_image != .instance_image then
						{update: true, recreate: true}
					else {} end
					+ if .bind_wan_ip or .unbind_wan_ip then
						{update: true}
					else {} end
				else {} end)' || return 1
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
	echo "[ERROR] instance_image - '$IMAGE_NAME' not found" >&2
	return 1
}

instances_acquire_ip(){
	local LOOKUP_IP="$1" STAGE="$NPC_STAGE/nce-ips"
	[ ! -z "$LOOKUP_IP" ] || return 1
	[ "$LOOKUP_IP" != "new" ] && [ "$LOOKUP_IP" != "true" ] && {
		( exec 100>$STAGE.lock && flock 100
			[ ! -f $STAGE ] && {
				npc api 'json.ips|arrays' GET '/api/v1/ips?status=available&type=nce&offset=0&limit=9999' >$STAGE || rm -f $STAGE
			}
			[ -f $STAGE ] && LOOKUP_IP="$LOOKUP_IP" jq -c '(map(select(env.LOOKUP_IP=="any" or .ip==env.LOOKUP_IP))|.[0])as $match | if $match then ($match, map(select(.id != $match.id))) else empty end' $STAGE | {
				read -r MATCH && [ ! -z "$MATCH" ] && read -r IPS && echo "$IPS" >$STAGE && echo "$MATCH"
			}
		) && return 0
		[ "$LOOKUP_IP" != "any" ] && {
			echo "[ERROR] ip=$LOOKUP_IP not available" >&2
			return 1
		}
	}
	npc api 'json.ips|arrays|.[0]//empty' POST '/api/v1/ips' '{"nce": 1}' && return 0
	echo "[ERROR] failed to create ip" >&2
	return 1
}

instances_prepare(){
	local INSTANCE="$1" 
	jq -ce 'select(.prepared)'<<<"$INSTANCE" && return 0

	local IMAGE_ID
	jq_check '.create or .recreate'<<<"$INSTANCE" && {
		local IMAGE_NAME="$(jq -r '.instance_image//.default_instance_image//empty'<<<"$INSTANCE")"
		[ ! -z "$IMAGE_NAME" ] && IMAGE_ID="$(instances_lookup_image "$IMAGE_NAME")" && [ ! -z "$IMAGE_ID" ] || return 1

		jq -r '.ssh_keys//empty|.[]'<<<"$INSTANCE" | check_ssh_keys || return 1
	}
	local WAN_IP
	jq_check '.bind_wan_ip and (.rebind_wan_ip|not)'<<<"$INSTANCE" && {
		WAN_IP="$(instances_acquire_ip "$(jq -r '.wan_ip'<<<"$INSTANCE")")" && [ ! -z "$WAN_IP" ] || return 1
	}
	local WAN_CONFIG="$(jq --argjson acquired "${WAN_IP:-"{}"}" -c '{
		wan_ip: ($acquired.ip//.wan_ip//.actual_wan_ip),
		wan_id: ($acquired.id//.wan_id//.actual_wan_id),
		wan_capacity: (.wan_capacity//.actual_wan_capacity)
	} | select(.wan_ip)//{}'<<<"$INSTANCE")"
	
	IMAGE_ID="$IMAGE_ID" \
	jq -c '. + {
		prepared: true,
		image_id: env.IMAGE_ID,
		cpu_weight: (.instance_type.cpu//.default_instance_type.cpu//2),
		memory_weight: ((.instance_type.memory//.default_instance_type.memory//"4G")|sub("[Gg]$"; "")|tonumber),
		ssd_weight: 20,
		description:"created by npc-setup"
	}'"+$WAN_CONFIG"<<<"$INSTANCE" && return 0 || return 1
}

instances_create(){
	local INSTANCE="$(instances_prepare "$1")" RESULT="$2" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	local CREATE_INSTANCE="$(jq -c '{
			bill_info: "HOUR",
			server_info: {
				azCode: (.zone//.az//"A"),
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
		local RESPONSE="$(npc api 'json|((arrays|{id:.[0]})//{})+(objects//{})' POST /api/v1/vm "$CREATE_INSTANCE")" \
			&& [ ! -z "$RESPONSE" ] || return 1
		local INSTANCE_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" && [ ! -z "$INSTANCE_ID" ] && {
			while action_check_continue "$CTX"; do
				npc api "json|$MAPPER_LOAD_INSTANCE|select($FILTER_LOAD_INSTANCE)" GET "/api/v1/vm/$INSTANCE_ID" \
					| jq_check --argjson instance "$INSTANCE" 'select(.)|$instance + .' --out $RESULT \
					&& {
						echo "[INFO] instance '$INSTANCE_ID' created." >&2
						instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
						return 0
					}
				sleep "$NPC_ACTION_PULL_SECONDS"
			done
			return 1
		}
		echo "[ERROR] $RESPONSE" >&2
		# {"code":4030001,"msg":"Api freq out of limit."}
		[ "$(jq -r .code <<<"$RESPONSE")" = "4030001" ] && ( 
			exec 100>$NPC_STAGE/instances.retries && flock 100
			WAIT_SECONDS="$NPC_ACTION_RETRY_SECONDS"
			action_check_continue "$CTX" && while sleep 1s && action_check_continue "$CTX"; do
				(( --WAIT_SECONDS > 0 )) || exit 0
			done; exit 1
		) && continue
		return 1
	done
}

instances_update_wan(){
	local INSTANCE_ID="$1" INSTANCE="$2" CTX="$3" UPDATE_LOCK="$NPC_STAGE/instances.update_wan"
	jq_check '.update and (.recreate|not) and .unbind_wan_ip'<<<"$INSTANCE" &&{
		local PARAMS="$(jq -r '@uri "pubIp=\(.actual_wan_ip)&portId=\(.actual_wan_id)"'<<<"$INSTANCE")"
		(exec 100>$UPDATE_LOCK && flock 100 && instances_api DELETE "/api/v1/vm/$INSTANCE_ID/action/unmountPublicIp?$PARAMS") || {
			echo '[ERROR] failed to unbind wan_ip.' >&2
			return 1
		}
		while action_check_continue "$CTX"; do
			npc api 'json|select(.status=="available")' \
				GET "$(jq -r '@uri "/api/v1/ips/\(.actual_wan_id)"'<<<"$INSTANCE")" \
				| jq_check '.ip' && break
			sleep "$NPC_ACTION_PULL_SECONDS"
		done || return 1
	} 
	jq_check '.bind_wan_ip'<<<"$INSTANCE" &&{
		local PARAMS="$(jq -r '@uri "pubIp=\(.wan_ip)&portId=\(.wan_id)&qosMode=netflow&bandWidth=\(.wan_capacity//"1M"|sub("[Mm]$"; "")|tonumber)"'<<<"$INSTANCE")"
		(exec 100>$UPDATE_LOCK && flock 100 && instances_api PUT "/api/v1/vm/$INSTANCE_ID/action/mountPublicIp?$PARAMS") || {
			echo '[ERROR] failed to bind wan_ip.' >&2
			return 1
		}
		while action_check_continue "$CTX"; do
			npc api 'json|select(.status=="binded")' \
				GET "$(jq -r '@uri "/api/v1/ips/\(.wan_id)"'<<<"$INSTANCE")" \
				| jq_check '.ip' && break
			sleep "$NPC_ACTION_PULL_SECONDS"
		done || return 1
	}
	return 0
}

instances_update(){
	local INSTANCE="$(instances_prepare "$1")" RESULT="$2" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	jq_check '.recreate'<<<"$INSTANCE" && {
		instances_destroy "$INSTANCE" "$RESULT" "$CTX" \
			&& instances_create "$INSTANCE" "$RESULT" "$CTX" \
			&& return 0
		return 1
	}
	local INSTANCE_ID="$(jq -r .id<<<"$INSTANCE")"
	instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
	echo "[INFO] instance '$INSTANCE_ID' updated." >&2
	return 0
}

instances_destroy(){
	local INSTANCE="$1"
	local INSTANCE_ID="$(jq -r .id<<<"$INSTANCE")"
	instances_api DELETE "/api/v1/vm/$INSTANCE_ID" && {
		echo "[INFO] instance '$INSTANCE_ID' destroyed." >&2
		return 0
	}
	return 1
}

instances_api(){
	local FILTER; [[ "$1" =~ ^(GET|POST|PUT|DELETE|HEAD)$ ]] || {
		FILTER="$1" && shift
	}
	local RESPONSE="$(npc api --error "$@")"
	[ ! -z "$RESPONSE" ] && [ "$(jq -r .code <<<"$RESPONSE")" = "200" ] && {
		[ -z "$FILTER" ] && return 0 || {
			jq -ce "($FILTER)//empty" <<<"$RESPONSE" && return 0
		}
	}
	echo "[ERROR] $RESPONSE" >&2
	return 1
}
