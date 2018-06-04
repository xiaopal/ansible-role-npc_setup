#! /bin/bash

setup_resources "load_balancings"
setup_resources "load_balancing_target_groups"
#setup_resources "load_balancing_listeners"
JQ_LOAD_BALANCINGS='.npc_load_balancings[]?'
JQ_LOAD_BALANCING_TARGET_GROUPS='.npc_load_balancing_target_groups[]?, ('"$JQ_LOAD_BALANCINGS"'|select(.present != false) | . as $load_balancing | .target_groups[]? | .target_group |= "\(.)@\($load_balancing.name)")'
JQ_LOAD_BALANCING_LISTENERS='.npc_load_balancing_listeners[]?, ('"$JQ_LOAD_BALANCINGS"'|select(.present != false) | . as $load_balancing | .listeners[]? | .listener |= "\(.)@\($load_balancing.name)")'
JQ_LOAD_BALANCINGS_FILTER='{
	name: .Name,
	id: .InstanceId,
	address: .Address,
	address_type: .Network
}'

load_balancings_lookup(){
	local LOAD_BALANCING="$1" FILTER="${2:-.InstanceId}" STAGE="$NPC_STAGE/load_balancings.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
 			checked_api2 'arrays' GET '/nlb?Action=GetLoadBalancers&Version=2017-12-05&Limit=200' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$LOAD_BALANCING" ] && [ -f $STAGE ] && LOAD_BALANCING="$LOAD_BALANCING" \
 		jq_check --stdout '.[]|select(.InstanceId == env.LOAD_BALANCING or .Name == env.LOAD_BALANCING)|'"$FILTER" $STAGE \
 		&& return 0
 	echo "[ERROR] Load balancing '$LOAD_BALANCING' not found" >&2
 	return 1
 }

init_load_balancings(){
	local INPUT="$1" STAGE="$2"
	jq_check "$JQ_LOAD_BALANCINGS" $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c "[ $JQ_LOAD_BALANCINGS ]" $INPUT || >>$STAGE.error) \
			<(checked_api2 "arrays|map($JQ_LOAD_BALANCINGS_FILTER)" \
                GET '/nlb?Action=GetLoadBalancers&Version=2017-12-05&Limit=200' || >>$STAGE.error) \
			'. + {update: false}' || return 1
	}
	return 0
}

load_balancings_create(){
	local LOAD_BALANCING="$1" RESULT="$2" CTX="$3" && [ ! -z "$LOAD_BALANCING" ] || return 1

	local VPC_NETWORK VPC_SUBNET_MAPPINGS VPC_SECURITY_GROUP VPC_SUBNET
	VPC_NETWORK="$(vpc_networks_lookup "$(jq -r '.vpc_network//.vpc//empty'<<<"$LOAD_BALANCING")")" && \
		[ ! -z "$VPC_NETWORK" ] || return 1
	while read -r VPC_SUBNET; do
		local VPC_SUBNET_MAPPING="$(vpc_subnets_lookup "$VPC_SUBNET" "$VPC_NETWORK" '{id:.Id, zone:.ZoneId}')" && \
			[ ! -z "$VPC_SUBNET_MAPPING" ] || return 1
		VPC_SUBNET_MAPPINGS="$(jq --argjson mapping "$VPC_SUBNET_MAPPING" -c '. + [$mapping]'<<<"${VPC_SUBNET_MAPPINGS:-[]}")"
	done < <(jq -cr '.vpc_subnets[]?, .vpc_subnet//empty'<<<"$LOAD_BALANCING")
	[ ! -z "$VPC_SUBNET_MAPPINGS" ] || {
		echo "[ERROR] .vpc_subnets/.vpc_subnet required" >&2
		return 1
	}
	VPC_SECURITY_GROUP="$(vpc_security_groups_lookup "$(jq -r '.vpc_security_group//empty'<<<"$LOAD_BALANCING")" "$VPC_NETWORK")" \
		&& [ ! -z "$VPC_SECURITY_GROUP" ] || return 1
	
	local CREATE_LOAD_BALANCING="$(export VPC_NETWORK VPC_SECURITY_GROUP
		jq -r --argjson subnets "$VPC_SUBNET_MAPPINGS" '{
			Name: .name,
			Description: (.description//.comment),
			Type: "vpc_mix",
			Network: (.address_type//"public"),
			TopAzInfos: ($subnets|map({ TopAz: .zone, SubNetId: .id })),
			VpcId: env.VPC_NETWORK,
			SecurityGroups: [env.VPC_SECURITY_GROUP],
			Standard: {
				ChargeMode: "netflow",
				ChargeType: "AMOUNT",
				BandwidthLimit: (.capacity//"10M"|sub("[Mm]$"; "")|tonumber)
			}
		}|with_entries(select(.value))'<<<"$LOAD_BALANCING")"
    local CREATE_RESPONSE="$(NPC_API_LOCK="$NPC_STAGE/load_balancings.create_lock" checked_api2 '.' \
		POST '/nlb?Action=CreateLoadBalancer&Version=2017-12-05' "$CREATE_LOAD_BALANCING")" && [ ! -z "$CREATE_RESPONSE" ] && \
	jq_check "select(.InstanceId)|$JQ_LOAD_BALANCINGS_FILTER| \$nlb + ." --argjson nlb "$LOAD_BALANCING" --out $RESULT <<<"$CREATE_RESPONSE" && {
		echo "[INFO] Load balancing '$(jq -r '"\(.InstanceId)(\(.Name))"'<<<"$CREATE_RESPONSE")' created." >&2
		return 0
	}
	return 1
}

load_balancings_destroy(){
	local LOAD_BALANCING="$1" RESULT="$2" CTX="$3" && [ ! -z "$LOAD_BALANCING" ] || return 1
	local DELETE_ID="$(jq -r .id<<<"$LOAD_BALANCING")" && [ ! -z "$DELETE_ID" ] || return 1
	NPC_API_SUCCEED_NO_RESPONSE='Y' \
    checked_api2 GET "/nlb?Action=DeleteLoadBalancer&InstanceId=$DELETE_ID&Version=2017-12-05" && {
        echo "[INFO] Load balancing '$DELETE_ID($(jq -r .name<<<"$LOAD_BALANCING"))' deleted." >&2
        return 0
    }
	return 1
}

init_load_balancing_target_groups(){
	local INPUT="$1" STAGE="$2" LOAD_BALANCING LOAD_BALANCING_ID
	local JQ_TARGETS_MAPPER='map(if strings//false then capture("(?<instance>[\\w\\-]+)(?:[\\:/](?<port>\\d+))?(?:[\\:/](?<weight>\\d+))?")|with_entries(select(.value)) else . end
		| if .instance then . else error("target_group .instance required") end
		| if .port then .port |= tonumber else error("target_group .port required") end
		| if .weight then .weight |= tonumber else . end
		)'
	jq_check "$JQ_LOAD_BALANCING_TARGET_GROUPS" $INPUT || return 0
    (jq -c "[ $JQ_LOAD_BALANCING_TARGET_GROUPS ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='target_group' \
		expand_resources 'map(select(.target_group)
			| . + (.target_group | capture("(?<target_group_name>[\\w\\-]+)(?:@(?<load_balancing>[\\w\\-]+))?")|with_entries(select(.value)))
			| select((.target_group_name and .load_balancing)//error("target_group .target_group_name and .load_balancing required"))
			| if .targets then .targets |= '"$JQ_TARGETS_MAPPER"' else . end
			| if .present_targets then .present_targets |= '"$JQ_TARGETS_MAPPER"' else . end
			| if .absent_targets then .absent_targets |= '"$JQ_TARGETS_MAPPER"' else . end
			)' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map(.load_balancing//empty)|unique[]' $STAGE.expand | while read -r LOAD_BALANCING _; do  LOAD_BALANCING="$LOAD_BALANCING" \
		load_balancings_lookup "$LOAD_BALANCING" '"\(env.LOAD_BALANCING) \(.InstanceId)"' || echo "$LOAD_BALANCING"
    done | sort -u | while read -r LOAD_BALANCING LOAD_BALANCING_ID; do
        [ ! -z "$LOAD_BALANCING_ID" ] || { LOAD_BALANCING="$LOAD_BALANCING" \
            jq_check '.[]|select(.load_balancing == env.LOAD_BALANCING and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export LOAD_BALANCING LOAD_BALANCING_ID
            local LOAD_FILTER='{
                id: .TargetGroupId,
                target_group_name: .Name,
				actual_targets: (.Instances | map({
					instance_id: .Id,
					instance_name: .Name,
					instance_lan_ip: .Address,
					instance_zone: .TopAz,
					port: .Port,
					weight: .Weight
				}))
            }' TARGET_GROUP_FILTER='.+{
                name: "\(.target_group_name)@\(env.LOAD_BALANCING_ID)",
                load_balancing_id: env.LOAD_BALANCING_ID
            }'
            jq -c "map(select(.load_balancing == env.LOAD_BALANCING)|$TARGET_GROUP_FILTER)" $STAGE.expand >>$STAGE.init0 || exit 1
			checked_api2 ".TargetGroups//empty|map($LOAD_FILTER|$TARGET_GROUP_FILTER)" \
				GET "/nlb?Action=GetLoadBalancer&InstanceId=$LOAD_BALANCING_ID&Version=2017-12-05" >>$STAGE.init1
        ) || { >>$STAGE.error; break; }
    done

	jq_remove_targets(){
		echo "($2) as \$remove_targets | $1"' | map(select(
			. as $actual_target | $remove_targets | 
			all($actual_target.port == .port and (
				$actual_target.instance_name == .instance_name or 
				$actual_target.instance_id == .instance_id or 
				$actual_target.instance_name == .instance or 
				$actual_target.instance_id == .instance) | not) ))'
	}
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
			' . + (if (.create or .update) and (.targets | not) and (.present_targets or .absent_targets) then
					{ targets: ( 
						('"$(jq_remove_targets '.actual_targets//[]' '(.absent_targets//[]) + (.present_targets//[])')"')
						+ (.present_targets//[])) }
				else {} end)
			| .update = (.update and .targets and (
				(.targets|length) == (.actual_targets|length) and
				(('"$(jq_remove_targets '.actual_targets' '.targets')"') + .targets|sort) == (.targets|sort) 
				| not ))' || return 1
	return 0
}

load_balancing_target_groups_prepare(){
	local LOAD_BALANCING_TARGET_GROUP="$1"
	jq -ce 'select(.prepared)'<<<"$LOAD_BALANCING_TARGET_GROUP" && return 0

	local TARGETS='[]' TARGET INSTANCE
	while read -r TARGET; do
		INSTANCE='{}'; jq_check '.instance_id'<<<"$TARGET" || {
			INSTANCE="$(instances_lookup "$(jq -r '.instance'<<<"$TARGET")" '{
				instance_id: .id,
				instance_name: .name,
				instance_lan_ip: .lan_ip,
				instance_zone: .zone
				}')" && [ ! -z "$INSTANCE" ] || return 1
		}
		TARGETS="$(jq --argjson target "$TARGET" --argjson instance "$INSTANCE" -c '. + [$target + $instance]'<<<"$TARGETS")"
	done < <(jq -c '.targets//.actual_targets|.[]'<<<"$LOAD_BALANCING_TARGET_GROUP")
	jq -c --argjson targets "$TARGETS" '. + {
		prepared: true,
		targets: $targets
	}' <<<"$LOAD_BALANCING_TARGET_GROUP"
}

load_balancing_target_groups_create(){
	local LOAD_BALANCING_TARGET_GROUP="$(load_balancing_target_groups_prepare "$1")" RESULT="$2" CTX="$3" && [ ! -z "$LOAD_BALANCING_TARGET_GROUP" ] || return 1
	local CREATE_TARGET_GROUP="$(jq -c '{
			Name: .target_group_name,
			InstanceId: .load_balancing_id,
			Instances: (.targets | map({
				Id: .instance_id,
				Name: .instance_name,
				Address: .instance_lan_ip,
				TopAz: .instance_zone,
				Port: .port,
				Weight: .weight
			} | with_entries(select(.value))))
		}'<<<"$LOAD_BALANCING_TARGET_GROUP")"
    local CREATE_ID="$(NPC_API_LOCK="$NPC_STAGE/load_balancing_target_groups.create_lock" checked_api2 '.TargetGroupId' \
			POST "/nlb?Action=CreateTargetGroup&Version=2017-12-05" "$CREATE_TARGET_GROUP")" \
        && [ ! -z "$CREATE_ID" ] && {
			echo "[INFO] load balancing target_group '$CREATE_ID' created." >&2
			return 0
        }
	echo "[ERROR] Failed to create load balancing target_group: $CREATE_TARGET_GROUP" >&2
	return 1
}

load_balancing_target_groups_update(){
	local LOAD_BALANCING_TARGET_GROUP="$(load_balancing_target_groups_prepare "$1")" RESULT="$2" CTX="$3" && [ ! -z "$LOAD_BALANCING_TARGET_GROUP" ] || return 1
	local UPDATE_TARGET_GROUP="$(jq -c '{
			InstanceId: .load_balancing_id,
			TargetGroupId: .id,
			Instances: (.targets | map({
				Id: .instance_id,
				Name: .instance_name,
				Address: .instance_lan_ip,
				TopAz: .instance_zone,
				Port: .port,
				Weight: .weight
			} | with_entries(select(.value))))
		}'<<<"$LOAD_BALANCING_TARGET_GROUP")"

	NPC_API_SUCCEED_NO_RESPONSE='Y' \
	NPC_API_LOCK="$NPC_STAGE/load_balancing_target_groups.update_lock" \
	checked_api2 POST "/nlb?Action=UpdateTargetGroup&Version=2017-12-05" "$UPDATE_TARGET_GROUP" && {
		echo "[INFO] load balancing target_group '$(jq -r .id<<<"$LOAD_BALANCING_TARGET_GROUP")' updated." >&2
		return 0
	}
	echo "[ERROR] Failed to update load balancing target_group: $UPDATE_TARGET_GROUP" >&2
	return 1
}

load_balancing_target_groups_destroy(){
	local LOAD_BALANCING_TARGET_GROUP="$1" RESULT="$2" CTX="$3" && [ ! -z "$LOAD_BALANCING_TARGET_GROUP" ] || return 1
	local DELETE_ID="$(jq -r .id<<<"$LOAD_BALANCING_TARGET_GROUP")" && [ ! -z "$DELETE_ID" ] || return 1
	NPC_API_SUCCEED_NO_RESPONSE='Y' \
    checked_api2 GET "/nlb?Action=DeleteTargetGroup&InstanceId=$(jq -r .load_balancing_id<<<"$LOAD_BALANCING_TARGET_GROUP")&TargetGroupId=$DELETE_ID&Version=2017-12-05" && {
		echo "[INFO] load balancing target_group '$DELETE_ID' deleted." >&2
        return 0
    }
	return 1
}
