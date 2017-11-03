#! /bin/bash

setup_resources "instances"

MAPPER_PRE_LOAD_INSTANCE='{
		id: .uuid,
		name: .name,
		status: .status,
		lan_ip: .vnet_ip,

		inet_ip: (.public_ip//false),
		corp_ip: (.private_ip//false),
		
		actual_volumes: (.uuid as $uuid |.attached_volumes//[]|map({
			key:.name,
			value:{
				name:.name, 
				instance_id: $uuid,
				volume_uuid: .volumeId,
				device: .mountPath
			}
		})|from_entries),
		actual_wan_ip: (.public_ip//false),
		actual_wan_id: (.public_port_id//false),
		actual_wan_capacity: (if .bandWidth then "\(.bandWidth|tonumber)M" else false end),
		actual_image: .images[0].imageName,
		actual_type: { cpu:.vcpu, memory:"\(.memory_gb)G"}
	}'
MAPPER_LOAD_INSTANCE='. + (if .volumes then
			{volumes: ((.volumes//{}) * (.actual_volumes//{})|with_entries(select(.value.present)))}
		else {} end)
	| . + (if .missing_ssh_key|not then
			{ssh_key_file:(.ssh_key_file//.default_ssh_key_file)} 
		else {} end)
	| . + (if (.wan_ip=="new" or .wan_ip==true or .wan_ip=="any") and .actual_wan_ip then 
			{wan_ip: .actual_wan_ip} 
		else {} end)'
FILTER_LOAD_INSTANCE='select(.)|$instance + .|'"$MAPPER_LOAD_INSTANCE"
FILTER_INSTANCE_STATUS='.status=="ACTIVE" and .lan_ip'
FILTER_PLAN_VOLUMES='. + (if .volumes then
		{plan_volumes: (
			(.volumes//{} | with_entries(.value |= . + {actual_present: false}))
			* (.actual_volumes//{} | with_entries(.value |= . + {actual_present: true})) 
			| with_entries(.value |= . + {
				mount: ((.actual_present|not) and .present), 
				unmount: (.actual_present and (.present|not)) 
			})
		)}
	else {} end)'

init_instances(){
	local INPUT="$1" STAGE="$2"

	load_instances(){
		local PAGE_SIZE=50 PAGE_NUM=1
		while (( PAGE_SIZE > 0 )); do
			local PARAMS="pageSize=$PAGE_SIZE&pageNum=$PAGE_NUM" && PAGE_SIZE=0
			while read -r INSTANCE_ENTRY; do
				PAGE_SIZE=50 && jq -c "select(.)|"'
					if (env.NPC_SSH_KEY|length==0) or (try .properties|fromjson["publicKeys"]|split(",")|contains([env.NPC_SSH_KEY])|not) then 
						(select(env.ACTION_FILTER_BY_SSH_KEY|length==0)|. + {missing_ssh_key: true})
						else . end
					|'"$MAPPER_PRE_LOAD_INSTANCE"'
					| if '"$FILTER_INSTANCE_STATUS"' then . else . + {error: "\(.name): status=\(.status), lan_ip=\(.lan_ip)"} end						
				'<<<"$INSTANCE_ENTRY"
			done < <(npc api 'json.instances[]' GET "/api/v1/vm/allInstanceInfo?$PARAMS") 
			(( PAGE_NUM += 1 ))
		done | jq -sc '.'
		return 0
	}
	jq_check '.npc_instances|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '. as $input | .npc_instances | map( . 
				+ {default_instance_image: $input.npc_instance_image, default_instance_type: $input.npc_instance_type}
				+ ( if env.NPC_SSH_KEY|length>0 then {ssh_keys:((.ssh_keys//[])+[env.NPC_SSH_KEY]|unique)} else {} end )
				+ ( if env.NPC_SSH_KEY_FILE|length>0 then {default_ssh_key_file: env.NPC_SSH_KEY_FILE} else {} end )
				)' $INPUT || >>$STAGE.error) \
			<(load_instances || >>$STAGE.error) \
			'. + (if .volumes then {volumes: (.volumes|map({ key: ., value: {name:., present: true}})|from_entries)} else {} end)
			|'"$MAPPER_LOAD_INSTANCE"'
			|. + (if .wan_ip then
					if .actual_wan_ip|not then
						{plan_wan_ip:{bind: true}}
					elif .wan_ip != .actual_wan_ip then
						{plan_wan_ip:{bind: true, unbind: true}}
					elif .wan_capacity and (.wan_capacity|ascii_upcase) != .actual_wan_capacity then
						{plan_wan_ip:{bind: true, unbind: true, rebind:true}}
					else {} end
				elif .wan_ip == false and .actual_wan_ip then
					{plan_wan_ip:{unbind: true}}
				else {} end) 
			|'"$FILTER_PLAN_VOLUMES"'
			|. + (if .update then {update: false}
# do not recreate
#					+ if  .instance_type and .actual_type != .instance_type then
#						{update: true, recreate: true}
#					else {} end
#					+ if .instance_image and .actual_image != .instance_image then
#						{update: true, recreate: true}
#					else {} end
					+ if .plan_volumes then 
						# and (.plan_volumes|map(select(.mount or .unmount))|length>0) then
						{update: true, update_volumes: true}
					else {} end
					+ if .plan_wan_ip then
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
		local IMAGE_NAME="$(jq -r '.instance_image//.default_instance_image//empty'<<<"$INSTANCE")" && [ ! -z "$IMAGE_NAME" ] || {
			echo '[ERROR] instance_image required.' >&2
			return 1
		} 
		IMAGE_ID="$(instances_lookup_image "$IMAGE_NAME")" && [ ! -z "$IMAGE_ID" ] || return 1

		jq -r '.ssh_keys//empty|.[]'<<<"$INSTANCE" | check_ssh_keys || return 1
	}
	
	jq_check '.volumes'<<<"$INSTANCE" && while read -r VOLUME; do
		jq_check '.present'<<<"$VOLUME" && {
			volumes_lookup "$(jq -r '.name'<<<"$VOLUME")">/dev/null || return 1 
		}
	done < <(jq -c '.volumes[]'<<<"$INSTANCE")

	local WAN_IP
	jq_check '.plan_wan_ip and .plan_wan_ip.bind and (.plan_wan_ip.rebind|not)'<<<"$INSTANCE" && {
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

instances_wait_instance(){
	local INSTANCE_ID="$1" CTX="$2" && shift && shift && [ ! -z "$INSTANCE_ID" ] || return 1
	local ARGS=("$@") && (( ${#ARGS[@]} > 0)) || ARGS=('select(.)') 
	while action_check_continue "$CTX"; do
		npc api "json|$MAPPER_PRE_LOAD_INSTANCE|select($FILTER_INSTANCE_STATUS)" GET "/api/v1/vm/$INSTANCE_ID" \
			| jq_check "${ARGS[@]}" \
			&& return 0
		sleep "$NPC_ACTION_PULL_SECONDS"
	done
	return 1
}

instances_create(){
	local INSTANCE="$(instances_prepare "$1")" RESULT="$2" CTX="$3" && [ -z "$INSTANCE" ] && return 1
	local CREATE_INSTANCE="$(jq -c '{
			bill_info: "HOUR",
			server_info: ({
				azCode: (.zone//.az),
				instance_name: .name,
				ssh_key_names: (.ssh_keys//[]),
				image_id: .image_id,
				cpu_weight: .cpu_weight,
				memory_weight: .memory_weight,
				ssd_weight: .ssd_weight,

				type: (.instance_type.type//.default_instance_type.type),
				series: (.instance_type.series//.default_instance_type.series),

				useVPC: (if .vpc_network then true else false end),
				networkId: (if .vpc_network then .vpc_network else false end),
				subnetId: (if .vpc_network then .vpc_subnet else false end),
				securityGroup:(if .vpc_network then .vpc_security_group else false end),
				usePrivateIP: (if .vpc_network and .vpc_corp then true else false end),
				useLifeCycleIP: (if .vpc_network and .vpc_inet then true else false end),
				bandwidth: (if .vpc_network and .vpc_inet then
						(.vpc_inet_capacity//"1M"|sub("[Mm]$"; "")|tonumber)
					else false end),

				description: .description
			} | with_entries(select(.value)))
		}'<<<"$INSTANCE")"
	while true; do
		local RESPONSE="$(api_create_instance "$CREATE_INSTANCE")" && [ ! -z "$RESPONSE" ] || return 1
		local INSTANCE_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" && [ ! -z "$INSTANCE_ID" ] \
			&& instances_wait_instance "$INSTANCE_ID" "$CTX" \
			&& {
				echo "[INFO] instance '$INSTANCE_ID' created." >&2 
				instances_update_volumes "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
				instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
				instances_wait_instance "$INSTANCE_ID" "$CTX" \
					--argjson instance "$INSTANCE" "$FILTER_LOAD_INSTANCE" --out $RESULT || return 1
				return 0
			}
		echo "[ERROR] $RESPONSE" >&2
		# {"code":4030001,"msg":"Api freq out of limit."}
		[ "$(jq -r .code <<<"$RESPONSE")" = "4030001" ] && ( 
			exec 100>$NPC_STAGE/instances.retries && flock 100 \
				&& action_sleep "$NPC_ACTION_RETRY_SECONDS" "$CTX" ) && continue
		return 1
	done
}

api_create_instance(){
	local CREATE_INSTANCE="$1"
	(
		exec 100>$NPC_STAGE/instances.create_lock && flock 100
		local RESPONSE="$(npc api --error 'json|((arrays|{id:.[0]})//{})+(objects//{})' POST /api/v1/vm "$CREATE_INSTANCE")" \
			&& echo "$RESPONSE" \
			&& [ ! -z "$RESPONSE" ]  \
			&& local INSTANCE_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" \
			&& [ ! -z "$INSTANCE_ID" ] \
			&& sleep 1s; # 等待1秒,避免 Api freq out of limit
	)	
}

instances_update_volumes(){
	local INSTANCE_ID="$1" INSTANCE="$2" CTX="$3" MOUNT_FILTER UNMOUNT_FILTER
	if jq_check '.volumes and (.create or .recreate)'<<<"$INSTANCE"; then
		# 等待10秒,期望云主机操作系统起来（否则可能导致绑定云硬盘失败）
		action_sleep 10s "$CTX" || return 1
		MOUNT_FILTER='select(.present)'
	elif jq_check '.volumes and .update and .update_volumes'<<<"$INSTANCE"; then
		INSTANCE="$(instances_wait_instance "$INSTANCE_ID" "$CTX" --stdout \
			--argjson instance "$INSTANCE" \
			"$FILTER_LOAD_INSTANCE | $FILTER_PLAN_VOLUMES")" \
			&& [ ! -z "$INSTANCE" ] || return 1
		jq_check '.plan_volumes and (.plan_volumes|map(select(.mount or .unmount))|length>0)'<<<"$INSTANCE" || return 0
		MOUNT_FILTER='select(.mount)'
		UNMOUNT_FILTER='select(.unmount)'
	else
		return 0
	fi
	[ ! -z "$UNMOUNT_FILTER" ] && {
		while read -r VOLUME_NAME; do
			volumes_unmount "$INSTANCE_ID" "$VOLUME_NAME" "$CTX" || return 1
		done < <(jq -cr ".plan_volumes[]|$UNMOUNT_FILTER|.name"<<<"$INSTANCE")
	}
	[ ! -z "$MOUNT_FILTER" ] && {
		while read -r VOLUME_NAME; do
			volumes_mount "$INSTANCE_ID" "$VOLUME_NAME" "$CTX" || return 1
		done < <(jq -cr ".plan_volumes[]|$MOUNT_FILTER|.name"<<<"$INSTANCE")
	}
	return 0
}

instances_update_wan(){
	local INSTANCE_ID="$1" INSTANCE="$2" CTX="$3" UPDATE_LOCK="$NPC_STAGE/instances.update_wan"
	jq_check '.update and (.recreate|not) and .plan_wan_ip and .plan_wan_ip.unbind'<<<"$INSTANCE" &&{
		local PARAMS="$(jq -r '@uri "pubIp=\(.actual_wan_ip)&portId=\(.actual_wan_id)"'<<<"$INSTANCE")"
		(exec 100>$UPDATE_LOCK && flock 100 && checked_api DELETE "/api/v1/vm/$INSTANCE_ID/action/unmountPublicIp?$PARAMS") || {
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
	jq_check '.plan_wan_ip and .plan_wan_ip.bind'<<<"$INSTANCE" &&{
		local PARAMS="$(jq -r '@uri "pubIp=\(.wan_ip)&portId=\(.wan_id)&qosMode=netflow&bandWidth=\(.wan_capacity//"1M"|sub("[Mm]$"; "")|tonumber)"'<<<"$INSTANCE")"
		(exec 100>$UPDATE_LOCK && flock 100 && checked_api PUT "/api/v1/vm/$INSTANCE_ID/action/mountPublicIp?$PARAMS") || {
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
	instances_wait_instance "$INSTANCE_ID" "$CTX" && {
		instances_update_volumes "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
		instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
		instances_wait_instance "$INSTANCE_ID" "$CTX" \
				--argjson instance "$INSTANCE" "$FILTER_LOAD_INSTANCE" --out $RESULT || return 1
		echo "[INFO] instance '$INSTANCE_ID' updated." >&2
		return 0
	}
	return 1
}

instances_destroy(){
	local INSTANCE="$1"
	local INSTANCE_ID="$(jq -r .id<<<"$INSTANCE")"
	checked_api DELETE "/api/v1/vm/$INSTANCE_ID" && {
		echo "[INFO] instance '$INSTANCE_ID' destroyed." >&2
		return 0
	}
	return 1
}
