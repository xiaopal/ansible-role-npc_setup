#! /bin/bash

# setup_resources "vpc_networks"
# setup_resources "vpc_subnets"
# setup_resources "vpc_security_groups"
# setup_resources "vpc_route_tables"

vpc_networks_lookup(){
	local NETWORK="$1" STAGE="$NPC_STAGE/vpc_networks.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
 			npc api2 GET '/vpc?Version=2017-11-30&Action=ListVpc&Limit=100' | jq -c '.Vpcs[]' \
                | jq -sc '.' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$NETWORK" ] && [ -f $STAGE ] && NETWORK="$NETWORK" \
 		jq_check --stdout '.[]|select(.Id == env.NETWORK or .Name == env.NETWORK or .CidrBlock == env.NETWORK)|.Id' $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC network '$NETWORK' not found" >&2
 	return 1
 }

vpc_subnets_lookup(){
	local SUBNET="$1" NETWORK="$(vpc_networks_lookup "$2")" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_subnets.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            npc api2 GET "/vpc?Version=2017-11-30&Action=ListSubnet&VpcId=$NETWORK&Limit=100" | jq -c '.Subnets[]' \
                | jq -sc '.' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$SUBNET" ] && [ -f $STAGE ] && SUBNET="$SUBNET" \
 		jq_check --stdout '.[]|select(.Id == env.SUBNET or .Name == env.SUBNET or .CidrBlock == env.SUBNET)|.Id' $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC subnet '$SUBNET' not found" >&2
 	return 1
 }

vpc_security_groups_lookup(){
	local GROUP="$1" NETWORK="$(vpc_networks_lookup "$2")" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_security_groups.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            npc api2 GET "/vpc?Version=2017-11-30&Action=ListSecurityGroup&VpcId=$NETWORK&Limit=100" | jq -c '.SecurityGroups[]' \
                | jq -sc '.' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$GROUP" ] && [ -f $STAGE ] && GROUP="$GROUP" \
 		jq_check --stdout '.[]|select(.Id == env.GROUP or .Name == env.GROUP)|.Id' $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC security group '$GROUP' not found" >&2
 	return 1
 }
