#! /bin/bash

setup_resources "vpc_networks"
setup_resources "vpc_subnets"
# setup_resources "vpc_security_groups"
# setup_resources "vpc_security_group_rules"
# setup_resources "vpc_route_tables"

vpc_networks_lookup(){
	local NETWORK="$1" FILTER="${2:-.Id}" STAGE="$NPC_STAGE/vpc_networks.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
 			checked_api2 '.Vpcs' GET '/vpc?Version=2017-11-30&Action=ListVpc&Limit=100' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$NETWORK" ] && [ -f $STAGE ] && NETWORK="$NETWORK" \
 		jq_check --stdout '.[]|select(.Id == env.NETWORK or .Name == env.NETWORK)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC network '$NETWORK' not found" >&2
 	return 1
 }

vpc_subnets_lookup(){
	local SUBNET="$1" NETWORK="$(vpc_networks_lookup "$2")" FILTER="${3:-.Id}" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_subnets.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            checked_api2 '.Subnets' GET "/vpc?Version=2017-11-30&Action=ListSubnet&VpcId=$NETWORK&Limit=100" >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$SUBNET" ] && [ -f $STAGE ] && SUBNET="$SUBNET" \
 		jq_check --stdout '.[]|select(.Id == env.SUBNET or .Name == env.SUBNET or .CidrBlock == env.SUBNET)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC subnet '$SUBNET' not found" >&2
 	return 1
 }

vpc_security_groups_lookup(){
	local GROUP="$1" NETWORK="$(vpc_networks_lookup "$2")" FILTER="${3:-.Id}" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_security_groups.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            checked_api2 '.SecurityGroups' GET "/vpc?Version=2017-11-30&Action=ListSecurityGroup&VpcId=$NETWORK&Limit=100" >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$GROUP" ] && [ -f $STAGE ] && GROUP="$GROUP" \
 		jq_check --stdout '.[]|select(.Id == env.GROUP or .Name == env.GROUP)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC security group '$GROUP' not found" >&2
 	return 1
 }

init_vpc_networks(){
	local INPUT="$1" STAGE="$2" LOAD_FILTER='{
		name: .Name,
		id: .Id,
		cidr: .CidrBlock
	}'
	jq_check '.npc_vpc_networks|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '.npc_vpc_networks//[]' $INPUT || >>$STAGE.error) \
			<(checked_api2 ".Vpcs//empty|map($LOAD_FILTER)" \
                GET '/vpc?Version=2017-11-30&Action=ListVpc&Limit=100' || >>$STAGE.error) \
			'. + {update: false}' || return 1
	}
	return 0
}

vpc_networks_create(){
	local VPC_NETWORK="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_NETWORK" ] || return 1
	local CREATE_VPC="$(jq -c '{
		Name: .name,
		CidrBlock: .cidr
	}'<<<"$VPC_NETWORK")"
    local VPC_ID="$(checked_api2 '.Vpc.Id' POST "/vpc?Version=2017-11-30&Action=CreateVpc" "$CREATE_VPC")" \
        && [ ! -z "$VPC_ID" ] && {
			echo "[INFO] VPC network '$VPC_ID' created." >&2
			return 0
        }
	return 1
}

vpc_networks_destroy(){
	local VPC_NETWORK="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_NETWORK" ] || return 1
	local VPC_ID="$(jq -r .id<<<"$VPC_NETWORK")" && [ ! -z "$VPC_ID" ] || return 1
    [ ! -z "$(checked_api2 '.Vpc.Id' GET "/vpc?Version=2017-11-30&Action=DeleteVpc&Id=$VPC_ID")" ] && {
        echo "[INFO] VPC network '$VPC_ID' deleted." >&2
        return 0
    }
	return 1
}

init_vpc_subnets(){
	local INPUT="$1" STAGE="$2"
	jq_check '.npc_vpc_subnets|arrays' $INPUT || return 0
    (jq -c '.npc_vpc_subnets//[]' $INPUT || >>$STAGE.error) | expand_resources >$STAGE.expand
    jq -r 'map(.network//empty)|unique[]' $STAGE.expand | while read -r NETWORK _; do
            NETWORK="$NETWORK" vpc_networks_lookup "$NETWORK" '"\(env.NETWORK) \(.Name) \(.Id)"' || echo "$NETWORK"
        done | sort -u | while read -r NETWORK NETWORK_NAME NETWORK_ID; do
        [ ! -z "$NETWORK_ID" ] || { NETWORK="$NETWORK" \
            jq_check '.[]|select(.network == env.NETWORK and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        >$STAGE.init0;  >$STAGE.init1;  
        ( export NETWORK NETWORK_NAME NETWORK_ID
            LOAD_FILTER='{
                name: .Name,
                id: .Id,
                zone: .ZoneId,
                cidr: .CidrBlock
            }'
            SUBNET_FILTER='.+{
                name: "\(env.NETWORK_NAME).\(.name)",
                subnet: .name,
                network_id: env.NETWORK_ID 
            }'
            jq -c "map(select(.network == env.NETWORK)|$SUBNET_FILTER)" $STAGE.expand >>$STAGE.init0 
            checked_api2 ".Subnets//empty|map($LOAD_FILTER|$SUBNET_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListSubnet&VpcId=$NETWORK_ID&Limit=100" >>$STAGE.init1
        )
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
        '. + {update: false}' || return 1
	return 0
}

vpc_subnets_create(){
	local VPC_SUBNET="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SUBNET" ] || return 1
	local CREATE_SUBNET="$(jq -c '{
		VpcId: .network_id,
		Name: .subnet,
		ZoneId: (.zone//.az),
		CidrBlock: .cidr
	}|with_entries(select(.value))'<<<"$VPC_SUBNET")"
    local SUBNET_ID="$(checked_api2 '.Subnet.Id' POST "/vpc?Version=2017-11-30&Action=CreateSubnet" "$CREATE_SUBNET")" \
        && [ ! -z "$SUBNET_ID" ] && {
			echo "[INFO] VPC subnet '$SUBNET_ID' created." >&2
			return 0
        }
	return 1
}

vpc_subnets_destroy(){
	local VPC_SUBNET="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SUBNET" ] || return 1
	local SUBNET_ID="$(jq -r .id<<<"$VPC_SUBNET")" && [ ! -z "$SUBNET_ID" ] || return 1
    [ ! -z "$(checked_api2 '.Subnet.Id' GET "/vpc?Version=2017-11-30&Action=DeleteSubnet&Id=$SUBNET_ID")" ] && {
        echo "[INFO] VPC subnet '$SUBNET_ID' deleted." >&2
        return 0
    }
	return 1
}

