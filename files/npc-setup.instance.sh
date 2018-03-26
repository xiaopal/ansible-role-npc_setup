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
			{volumes: ((.volumes//{}) * (.actual_volumes//{}))}
		else {} end)
	| . + {ssh_key_file:(.ssh_key_file//.default_ssh_key_file)}
	| . + (if (.wan_ip=="new" or .wan_ip==true or .wan_ip=="any") and .actual_wan_ip then 
			{wan_ip: .actual_wan_ip} 
		else {} end)'
FILTER_LOAD_INSTANCE='select(.)|$instance + .|'"$MAPPER_LOAD_INSTANCE"
FILTER_INSTANCE_STATUS='.lan_ip and (.status=="ACTIVE" or .status=="SHUTOFF")'
FILTER_PLAN_VOLUMES='. + (if .volumes then
		{plan_volumes: (
			(.volumes//{} | with_entries(.value |= . + {actual_present: false}))
			* (.actual_volumes//{} | with_entries(.value |= . + {actual_present: true})) 
			| with_entries(.value |= . + {
				mount: ((.actual_present|not) and .present), 
				unmount: (.actual_present and (.present == false)) 
			})
		)}
	else {} end)'

init_instances(){
	local INPUT="$1" STAGE="$2"

	jq_check '.npc_instances|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '. as $input | .npc_instances | map( . 
				+ ( if env.NPC_SSH_KEY|length>0 then {ssh_keys:((.ssh_keys//[])+[env.NPC_SSH_KEY]|unique)} else {} end )
				+ ( if env.NPC_SSH_KEY_FILE|length>0 then {default_ssh_key_file: env.NPC_SSH_KEY_FILE} else {} end )
				)' $INPUT || >>$STAGE.error) \
			<(load_instances "$MAPPER_PRE_LOAD_INSTANCE"'
					| if '"$FILTER_INSTANCE_STATUS"' then . else . + {error: "\(.name): status=\(.status), lan_ip=\(.lan_ip)"} end						
				'|| >>$STAGE.error) \
			'. + (if .volumes then {volumes: (.volumes|map(
					if (strings//false) then { key:., value: {name:., present: true}} else { key: .name, value: ({present: true} + .) } end
					)|from_entries)} else {} end)
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
					+ if .plan_volumes and (.plan_volumes|map(select(.mount or .unmount))|length>0) then
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
		IMAGE_ID="$(instances_lookup_image "$IMAGE_NAME" | head -1)" && [ ! -z "$IMAGE_ID" ] || return 1

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

	local VPC_CONFIG="{}" VPC_NETWORK VPC_SUBNET VPC_SECURITY_GROUP
	jq_check '.vpc_network//.vpc'<<<"$INSTANCE" && {
		VPC_NETWORK="$(vpc_networks_lookup "$(jq -r '.vpc_network//.vpc//empty'<<<"$INSTANCE")")" \
			&& [ ! -z "$VPC_NETWORK" ] || return 1
		VPC_SUBNET="$(vpc_subnets_lookup "$(jq -r '.vpc_subnet//empty'<<<"$INSTANCE")" "$VPC_NETWORK")" \
			&& [ ! -z "$VPC_SUBNET" ] || return 1
		VPC_SECURITY_GROUP="$(vpc_security_groups_lookup "$(jq -r '.vpc_security_group//empty'<<<"$INSTANCE")" "$VPC_NETWORK")" \
			&& [ ! -z "$VPC_SECURITY_GROUP" ] || return 1
		VPC_CONFIG="$(export VPC_NETWORK VPC_SUBNET VPC_SECURITY_GROUP; jq -nc '{
			vpc_network: env.VPC_NETWORK,
			vpc_subnet: env.VPC_SUBNET,
			vpc_security_group: env.VPC_SECURITY_GROUP
			}')"
	}
	
	IMAGE_ID="$IMAGE_ID" \
	jq -c '. + {
		prepared: true,
		instance_image_id: env.IMAGE_ID
	}'"+$WAN_CONFIG""+$VPC_CONFIG"<<<"$INSTANCE" && return 0 || return 1
}

instances_wait_instance(){
	local INSTANCE INSTANCE_ID="$1" CTX="$2" && shift && shift && [ ! -z "$INSTANCE_ID" ] || return 1
	local ARGS=("$@") && (( ${#ARGS[@]} > 0)) || ARGS=('select(.)') 
	while action_check_continue "$CTX"; do
		INSTANCE="$(npc api "json|$MAPPER_PRE_LOAD_INSTANCE" GET "/api/v1/vm/$INSTANCE_ID")" && [ ! -z "$INSTANCE" ] && {
			jq_check 'select(.status=="ERROR")'<<<"$INSTANCE" && {
				echo "[ERROR] instance '$INSTANCE_ID' status 'ERROR'." >&2 
				return 9
			}
			jq "select($FILTER_INSTANCE_STATUS)"<<<"$INSTANCE" | jq_check "${ARGS[@]}" && return 0
		}
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
				image_id: .instance_image_id,
				cpu_weight: (.instance_type.cpu//0),
				memory_weight: ((.instance_type.memory//"0G")|sub("[Gg]$"; "")|tonumber),
				ssd_weight: ((.instance_type.ssd//"20G")|sub("[Gg]$"; "")|tonumber),
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

				description: (.description//"created by npc-setup")
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

		# status == ERROR, @See instances_wait_instance
		[ "$?" == "9" ] && {
			instances_destroy "$(export INSTANCE_ID && jq -nc '{id: env.INSTANCE_ID}')" "$RESULT" "$CTX" && continue
			return 1
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
			&& [ ! -z "$INSTANCE_ID" ] 
			# \
			#&& sleep 1s; # 等待1秒,避免 Api freq out of limit
	)	
}

instances_update_volumes(){
	local INSTANCE_ID="$1" INSTANCE="$2" CTX="$3" MOUNT_FILTER UNMOUNT_FILTER WAIT_INSTANCE
	if jq_check '.volumes and (.create or .recreate)'<<<"$INSTANCE"; then
		# 云主机操作系统未就绪可能导致绑定云硬盘失败
		WAIT_INSTANCE="Y"
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
			volumes_mount "$INSTANCE_ID" "$VOLUME_NAME" "$CTX" "$WAIT_INSTANCE" || return 1
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

load_instances(){
	local PAGE_SIZE=50 PAGE_NUM FILTER="${1:-.}" PAGE_TOTAL PAGES=() FORKS FORK
	{
		PAGE_NUM=1 && read -r PAGE_TOTAL || return 1
		fork_next_page(){
			[ ! -z "$FORKS" ] || FORKS="$(mktemp -d)"
			(( PAGE_NUM ++ )) && local FORK="$PAGE_NUM"
			mkfifo "$FORKS/$FORK" && PAGES=("${PAGES[@]}" "$FORKS/$FORK" ) || return 1
			(
				npc api 'json.instances[]' GET "/api/v1/vm/allInstanceInfo?pageSize=$PAGE_SIZE&pageNum=$FORK" >"$FORKS/$FORK.load"
				cat "$FORKS/$FORK.load" >"$FORKS/$FORK" 
			) & return 0
		}
		(( PAGE_TOTAL > 1 )) && for FORK in $(seq 1 ${NPC_ACTION_FORKS:-1}); do
			(( PAGE_NUM < PAGE_TOTAL )) && fork_next_page || break
		done
		jq -c "select(.)|$FILTER"
		while [ ! -z "${PAGES[0]}" ]; do
			jq -c "select(.)|$FILTER" <"${PAGES[0]}"
			unset PAGES[0] && PAGES=("${PAGES[@]}")
			(( PAGE_NUM < PAGE_TOTAL )) && fork_next_page
		done
	 } < <(npc api 'json|.total_page,.instances[]' GET "/api/v1/vm/allInstanceInfo?pageSize=$PAGE_SIZE&pageNum=1") \
		| jq -sc '.'
	wait; [ ! -z "$FORKS" ] && rm -fr "$FORKS"
	return 0
}

instances_lookup(){
	local INSTANCE="$1" FILTER="${2:-.id}" STAGE="$NPC_STAGE/${INSTANCES_LOOKUP_KEY:-instances}.lookup"
	( exec 100>$STAGE.lock && flock 100
		[ ! -f $STAGE ] && {
			load_instances '{id: .uuid,name: .name}' >$STAGE || rm -f $STAGE
		}
	)
 	[ ! -z "$INSTANCE" ] && [ -f $STAGE ] && INSTANCE="$INSTANCE" \
 		jq_check --stdout '.[]|select(.id == env.INSTANCE or .name == env.INSTANCE)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] instance '$INSTANCE' not found" >&2
 	return 1
}

report_filters 'if .instances then 
		.instances |= map_values(
			if .volumes then 
				(.volumes |= with_entries(select(.value.present))) 
			else . end 
		) 
	else . end'