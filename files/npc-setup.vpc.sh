#! /bin/bash

setup_resources "vpc_networks"
setup_resources "vpc_route_tables"
setup_resources "vpc_subnets"
setup_resources "vpc_security_groups"
setup_resources "vpc_security_group_rules"

JQ_VPC_NETWORKS='.npc_vpc_networks[]?'
JQ_VPC_SUBNETS='.npc_vpc_subnets[]?, ('"$JQ_VPC_NETWORKS"'|select(.present != false) | . as $vpc | .subnets[]? | .subnet |= "\(.)@\($vpc.name)")'
JQ_VPC_SECURITY_GROUPS='.npc_vpc_security_groups[]?, ('"$JQ_VPC_NETWORKS"'|select(.present != false) | . as $vpc | .security_groups[]? | .security_group |= "\(.)@\($vpc.name)")'
JQ_VPC_SECURITY_GROUP_RULES='.npc_vpc_security_group_rules[]?, ('"$JQ_VPC_SECURITY_GROUPS"'|select(.present != false) | . as $security_group | .rules[]? | .rule |= "\(.)@\($security_group.security_group)")'
JQ_VPC_ROUTE_TABLES='.npc_vpc_route_tables[]?, ('"$JQ_VPC_NETWORKS"'|select(.present != false) | . as $vpc | .route_tables[]? | .route_table |= "\(.)@\($vpc.name)")'
JQ_VPC_ROUTES='.npc_vpc_routes[]?, ('"$JQ_VPC_ROUTE_TABLES"'|select(.present != false) | . as $route_table | .routes[]? | .route |= "\(.)@\($route_table.route_table)")'

vpc_networks_lookup(){
	local NETWORK="$1" FILTER="${2:-.Id}" STAGE="$NPC_STAGE/vpc_networks.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
 			checked_api2 '.Vpcs' GET '/vpc?Version=2017-11-30&Action=ListVpc&Limit=200' >$STAGE || rm -f $STAGE
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
            checked_api2 '.Subnets' GET "/vpc?Version=2017-11-30&Action=ListSubnet&VpcId=$NETWORK&Limit=200" >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$SUBNET" ] && [ -f $STAGE ] && SUBNET="$SUBNET" \
 		jq_check --stdout '.[]|select(.Id == env.SUBNET or .Name == env.SUBNET or .CidrBlock == env.SUBNET)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC subnet '$SUBNET' not found" >&2
 	return 1
 }

vpc_route_tables_lookup(){
	local TABLE="$1" NETWORK="$(vpc_networks_lookup "$2")" FILTER="${3:-.Id}" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_route_tables.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            checked_api2 '.RouteTables' GET "/vpc?Version=2017-11-30&Action=ListRouteTable&VpcId=$NETWORK&Limit=200" >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$TABLE" ] && [ -f $STAGE ] && TABLE="$TABLE" \
 		jq_check --stdout '.[]|select(.Id == env.TABLE or .Name == env.TABLE)|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] VPC route table '$TABLE' not found" >&2
 	return 1
 }

vpc_security_groups_lookup(){
	local GROUP="$1" NETWORK="$(vpc_networks_lookup "$2")" FILTER="${3:-.Id}" && [ ! -z "$NETWORK" ] || return 1
    local STAGE="$NPC_STAGE/vpc_security_groups.$NETWORK.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
            checked_api2 '.SecurityGroups' GET "/vpc?Version=2017-11-30&Action=ListSecurityGroup&VpcId=$NETWORK&Limit=200" >$STAGE || rm -f $STAGE
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
	jq_check "$JQ_VPC_NETWORKS" $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c "[ $JQ_VPC_NETWORKS ]" $INPUT || >>$STAGE.error) \
			<(checked_api2 ".Vpcs//empty|map($LOAD_FILTER)" \
                GET '/vpc?Version=2017-11-30&Action=ListVpc&Limit=200' || >>$STAGE.error) \
			'. + {update: false}' || return 1
	}
	return 0
}

vpc_networks_create(){
	local VPC_NETWORK="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_NETWORK" ] || return 1
	[ ! -z "$(jq -r .cidr<<<"$VPC_NETWORK")" ] || {
		echo "[ERROR] VPC network '$(jq -r .name<<<"$VPC_NETWORK")' required." >&2
		return 1
	}
	local CREATE_VPC="$(jq -c '{
		Name: .name,
		CidrBlock: .cidr,
		IsDefault: false
	}'<<<"$VPC_NETWORK")"
    local VPC_ID="$(NPC_API_LOCK="$NPC_STAGE/vpc_networks.create_lock" checked_api2 '.Vpc.Id' POST "/vpc?Version=2017-11-30&Action=CreateVpc" "$CREATE_VPC")" \
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

#  - subnet: defaultSubnet/192.168.0.0/24 @defaultVPCNetwork
#    zone: cn-east-1b
#  - subnet: 192.168.1.0/24 @defaultVPCNetwork
#    subnet_name: defaultSubnet
#    zone: cn-east-1b
#  - subnet: 192.168.1.0/24
#    subnet_name: defaultSubnet
#    vpc: defaultVPCNetwork
#    zone: cn-east-1b
init_vpc_subnets(){
	local INPUT="$1" STAGE="$2" VPC VPC_NAME VPC_ID
	jq_check "$JQ_VPC_SUBNETS" $INPUT || return 0
    (jq -c "[ $JQ_VPC_SUBNETS ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='subnet' \
		expand_resources 'map(select(.subnet)
			| . + (.subnet | capture("(?:(?<subnet_name>[\\w\\-]+)/)?(?<cidr>\\d+\\.\\d+\\.\\d+\\.\\d+/\\d+)(?:@(?<vpc>[\\w\\-]+))?")|with_entries(select(.value))) 
			| select(.cidr and .vpc)
			| . + {subnet_name: (.subnet_name//"subnet-\(.cidr|gsub("[\\./]+";"_"))")})' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map(.vpc//empty)|unique[]' $STAGE.expand | while read -r VPC _; do
            VPC="$VPC" vpc_networks_lookup "$VPC" '"\(env.VPC) \(.Id) \(.Name)"' || echo "$VPC"
        done | sort -u | while read -r VPC VPC_ID VPC_NAME; do
        [ ! -z "$VPC_ID" ] || { VPC="$VPC" \
            jq_check '.[]|select(.vpc == env.VPC and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export VPC VPC_NAME VPC_ID
            LOAD_FILTER='{
                subnet_name: .Name,
                id: .Id,
                zone: .ZoneId,
                cidr: .CidrBlock
            }'
            SUBNET_FILTER='.+{
                name: "\(.cidr)@\(env.VPC_NAME)",
                vpc_id: env.VPC_ID 
            }'
            jq -c "map(select(.vpc == env.VPC)|$SUBNET_FILTER)" $STAGE.expand >>$STAGE.init0 
            checked_api2 ".Subnets//empty|map($LOAD_FILTER|$SUBNET_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListSubnet&VpcId=$VPC_ID&Limit=200" >>$STAGE.init1
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
		VpcId: .vpc_id,
		Name: .subnet_name,
		ZoneId: (.zone//.az),
		CidrBlock: .cidr
	}|with_entries(select(.value))'<<<"$VPC_SUBNET")"
    local SUBNET_ID="$(NPC_API_LOCK="$NPC_STAGE/vpc_subnets.create_lock" checked_api2 '.Subnet.Id' POST "/vpc?Version=2017-11-30&Action=CreateSubnet" "$CREATE_SUBNET")" \
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

# - route_table: 'default@defaultVPCNetwork'
init_vpc_route_tables(){
	local INPUT="$1" STAGE="$2" VPC VPC_NAME VPC_ID
	jq_check "$JQ_VPC_ROUTE_TABLES" $INPUT || return 0
    (jq -c "[ $JQ_VPC_ROUTE_TABLES ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='route_table' \
		expand_resources 'map(select(.route_table)
			| . + (.route_table | capture("(?<route_table_name>[\\w\\-]+)(?:@(?<vpc>[\\w\\-]+))?")|with_entries(select(.value))) 
			| select(.route_table_name and .vpc))' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map(.vpc//empty)|unique[]' $STAGE.expand | while read -r VPC _; do
            VPC="$VPC" vpc_networks_lookup "$VPC" '"\(env.VPC) \(.Id) \(.Name)"' || echo "$VPC"
        done | sort -u | while read -r VPC VPC_ID VPC_NAME; do
        [ ! -z "$VPC_ID" ] || { VPC="$VPC" \
            jq_check '.[]|select(.vpc == env.VPC and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export VPC VPC_NAME VPC_ID
            LOAD_FILTER='{ route_table_name: .Name, id: .Id }'
            ROUTE_TABLE_FILTER='.+{
                name: "\(.route_table_name)@\(env.VPC_NAME)",
                vpc_id: env.VPC_ID 
            }'
            jq -c "map(select(.vpc == env.VPC)|$ROUTE_TABLE_FILTER)" $STAGE.expand >>$STAGE.init0 
            checked_api2 ".RouteTables//empty|map($LOAD_FILTER|$ROUTE_TABLE_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListRouteTable&VpcId=$VPC_ID&Limit=200" >>$STAGE.init1
        )
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
        '. + {update: false}' || return 1
	return 0
}

vpc_route_tables_create(){
	local VPC_ROUTE_TABLE="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_ROUTE_TABLE" ] || return 1
	local CREATE_ROUTE_TABLE="$(jq -c '{
		VpcId: .vpc_id,
		Name: .route_table_name
	}|with_entries(select(.value))'<<<"$VPC_ROUTE_TABLE")"
    local TABLE_ID="$(checked_api2 '.RouteTable.Id' POST "/vpc?Version=2017-11-30&Action=CreateRouteTable" "$CREATE_ROUTE_TABLE")" \
        && [ ! -z "$TABLE_ID" ] && {
			echo "[INFO] VPC route table '$TABLE_ID' created." >&2
			return 0
        }
	return 1
}

vpc_route_tables_destroy(){
	local VPC_ROUTE_TABLE="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_ROUTE_TABLE" ] || return 1
	local TABLE_ID="$(jq -r .id<<<"$VPC_ROUTE_TABLE")" && [ ! -z "$TABLE_ID" ] || return 1
    [ ! -z "$(NPC_API_LOCK="$NPC_STAGE/vpc_route_tables.create_lock" checked_api2 '.RouteTable.Id' GET "/vpc?Version=2017-11-30&Action=DeleteRouteTable&Id=$TABLE_ID")" ] && {
        echo "[INFO] VPC route table '$TABLE_ID' deleted." >&2
        return 0
    }
	return 1
}

# - security_group: 'default@defaultVPCNetwork'
init_vpc_security_groups(){
	local INPUT="$1" STAGE="$2" VPC VPC_NAME VPC_ID
	jq_check "$JQ_VPC_SECURITY_GROUPS" $INPUT || return 0
    (jq -c "[ $JQ_VPC_SECURITY_GROUPS ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='security_group' \
		expand_resources 'map(select(.security_group)
			| . + (.security_group | capture("(?<security_group_name>[\\w\\-]+)(?:@(?<vpc>[\\w\\-]+))?")|with_entries(select(.value))) 
			| select(.security_group_name and .vpc))' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map(.vpc//empty)|unique[]' $STAGE.expand | while read -r VPC _; do
            VPC="$VPC" vpc_networks_lookup "$VPC" '"\(env.VPC) \(.Id) \(.Name)"' || echo "$VPC"
        done | sort -u | while read -r VPC VPC_ID VPC_NAME; do
        [ ! -z "$VPC_ID" ] || { VPC="$VPC" \
            jq_check '.[]|select(.vpc == env.VPC and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export VPC VPC_NAME VPC_ID
            LOAD_FILTER='{ security_group_name: .Name, id: .Id }'
            SECURITY_GROUP_FILTER='.+{
                name: "\(.security_group_name)@\(env.VPC_NAME)",
                vpc_id: env.VPC_ID 
            }'
            jq -c "map(select(.vpc == env.VPC)|$SECURITY_GROUP_FILTER)" $STAGE.expand >>$STAGE.init0 
            checked_api2 ".SecurityGroups//empty|map($LOAD_FILTER|$SECURITY_GROUP_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListSecurityGroup&VpcId=$VPC_ID&Limit=200" >>$STAGE.init1
        )
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
        '. + {update: false}' || return 1
	return 0
}

vpc_security_groups_create(){
	local VPC_SECURITY_GROUP="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SECURITY_GROUP" ] || return 1
	local CREATE_SECURITY_GROUP="$(jq -c '{
		VpcId: .vpc_id,
		Name: .security_group_name
	}|with_entries(select(.value))'<<<"$VPC_SECURITY_GROUP")"
    local SECURITY_GROUP_ID="$(NPC_API_LOCK="$NPC_STAGE/vpc_security_groups.create_lock" checked_api2 '.SecurityGroup.Id' POST "/vpc?Version=2017-11-30&Action=CreateSecurityGroup" "$CREATE_SECURITY_GROUP")" \
        && [ ! -z "$SECURITY_GROUP_ID" ] && {
			echo "[INFO] VPC security group '$SECURITY_GROUP_ID' created." >&2
			return 0
        }
	return 1
}

vpc_security_groups_destroy(){
	local VPC_SECURITY_GROUP="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SECURITY_GROUP" ] || return 1
	local SECURITY_GROUP_ID="$(jq -r .id<<<"$VPC_SECURITY_GROUP")" && [ ! -z "$SECURITY_GROUP_ID" ] || return 1
    [ ! -z "$(checked_api2 '.SecurityGroup.Id' GET "/vpc?Version=2017-11-30&Action=DeleteSecurityGroup&Id=$SECURITY_GROUP_ID")" ] && {
        echo "[INFO] VPC security group '$SECURITY_GROUP_ID' deleted." >&2
        return 0
    }
	return 1
}

#  - rule: ingress, 192.168.0.0/24, all @defaultSecurityGroup @defaultVPCNetwork
#  - rule: egress,  10.1.1.1/32, all @defaultSecurityGroup @defaultVPCNetwork
#  - rule: ingress, 192.168.0.0/24, tcp/80 @defaultSecurityGroup @defaultVPCNetwork
#  - rule: ingress, 192.168.0.0/24, tcp/8000-9000 @defaultSecurityGroup @defaultVPCNetwork
#  - rule: ingress, default, tcp/8000-9000 @defaultSecurityGroup @defaultVPCNetwork
init_vpc_security_group_rules(){
	local INPUT="$1" STAGE="$2" VPC VPC_NAME \
		SECURITY_GROUP SECURITY_GROUP_NAME SECURITY_GROUP_ID 
	jq_check "$JQ_VPC_SECURITY_GROUP_RULES" $INPUT || return 0
    (jq -c "[ $JQ_VPC_SECURITY_GROUP_RULES ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='rule' \
		expand_resources 'map(select(.rule)
			| . + (.rule | capture("(?:(?<direction>ingress|egress),)?(?:(?<remote_addr>\\d+\\.\\d+\\.\\d+\\.\\d+)(?:/(?<remote_mask>\\d+))?|(?<remote_security_group>[\\w\\-]+))(?:,(?<protocol>[\\w\\-]+)(?:/(?<port_lo>\\d+)(?:\\-(?<port_hi>\\d+))?)?)?(?:@(?<security_group>[\\w\\-]+)@(?<vpc>[\\w\\-]+))?"))
			| select(.direction and .security_group and .vpc)
			| . + if .remote_addr then {remote_cidr: "\(.remote_addr)/\(.remote_mask//"32")"} else {} end
			| select(.remote_cidr or .remote_security_group)
			| . + {
				protocol: (.protocol//"all"|gsub("^all$";"ALLPROTOCOL";"i")|ascii_upcase),
				port_hi: (.port_hi//.port_lo)
			})' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map("\(.security_group) \(.vpc)")|unique[]' $STAGE.expand | while read -r SECURITY_GROUP VPC _; do
		( export SECURITY_GROUP VPC VPC_NAME="$(vpc_networks_lookup "$VPC" '.Name')"
			[ ! -z "$VPC_NAME" ] && vpc_security_groups_lookup "$SECURITY_GROUP" "$VPC" '"\(env.SECURITY_GROUP) \(env.VPC) \(.Id) \(.Name) \(env.VPC_NAME)"' \
				|| echo "$SECURITY_GROUP $VPC"
		)
        done | sort -u | while read -r SECURITY_GROUP VPC SECURITY_GROUP_ID SECURITY_GROUP_NAME VPC_NAME; do
        [ ! -z "$SECURITY_GROUP_ID" ] || { SECURITY_GROUP="$SECURITY_GROUP" VPC="$VPC" \
            jq_check '.[]|select(.vpc == env.VPC and .security_group == env.SECURITY_GROUP and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export SECURITY_GROUP VPC SECURITY_GROUP_ID SECURITY_GROUP_NAME VPC_NAME
            LOAD_FILTER='{
                id: .Id,
                direction: .Direction,
                protocol: .Protocol,
                port_lo: (.PortMin|if . != "-" then . else null end),
                port_hi: (.PortMax|if . != "-" then . else null end),
                remote_cidr: (.IpRange|if . != "-" then . else null end),
                remote_security_group_id: (.AuthorizedSecurityGroupId|if . != "-" then . else null end)
            }'
            RULE_FILTER='.+{
                name: "\(.direction),\(.remote_security_group_id//.remote_cidr),\(.protocol)/\(.port_lo//"-")/\(.port_hi//"-")@\(env.SECURITY_GROUP_NAME)@\(env.VPC_NAME)",
                security_group_id: env.SECURITY_GROUP_ID
            }'
            jq -c ".[]|select(.vpc == env.VPC and .security_group == env.SECURITY_GROUP)" $STAGE.expand | while read -r VPC_RULE; do
				[ ! -z "$VPC_RULE" ] || continue
				local REMOTE_GROUP="$(jq -r '.remote_security_group//empty' <<<"$VPC_RULE")" REMOTE_GROUP_ID \
					&& [ ! -z "$REMOTE_GROUP" ] && {
						REMOTE_GROUP_ID="$(vpc_security_groups_lookup "$REMOTE_GROUP" "$(jq -r '.vpc//empty' <<<"$VPC_RULE")")" \
							&& [ ! -z "$REMOTE_GROUP_ID" ] || {
								jq_check 'select(.present != false)' <<<"$VPC_RULE" || continue
								return 1
							}
					}
				REMOTE_GROUP_ID="$REMOTE_GROUP_ID" jq -c '.+{
					remote_security_group_id: (if .remote_security_group then env.REMOTE_GROUP_ID else null end)
				}'"|$RULE_FILTER"<<<"$VPC_RULE"
			done >>$STAGE.init0 
            checked_api2 ".SecurityGroupRules//empty|map($LOAD_FILTER|$RULE_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListSecurityGroupRule&SecurityGroupId=$SECURITY_GROUP_ID&Limit=200" >>$STAGE.init1
        )
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
        '. + {update: false}' || return 1
	return 0
}

vpc_security_group_rules_create(){
	local VPC_SECURITY_GROUP_RULE="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SECURITY_GROUP_RULE" ] || return 1
	local CREATE_RULE="$(jq -c '{
		SecurityGroupId: .security_group_id,
		Direction: .direction,
		IpRange: .remote_cidr,
		AuthorizedSecurityGroupId: .remote_security_group_id,
		Protocol: .protocol,
		PortMin: .port_lo,
		PortMax: .port_hi
	}|with_entries(select(.value))'<<<"$VPC_SECURITY_GROUP_RULE")"
    local RULE_ID="$(NPC_API_LOCK="$NPC_STAGE/vpc_security_group_rules.create_lock" checked_api2 '.SecurityGroupRule.Id' POST "/vpc?Version=2017-11-30&Action=CreateSecurityGroupRule" "$CREATE_RULE")" \
        && [ ! -z "$RULE_ID" ] && {
			echo "[INFO] VPC security group rule '$RULE_ID' created." >&2
			return 0
        }
	return 1
}

vpc_security_group_rules_destroy(){
	local VPC_SECURITY_GROUP_RULE="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_SECURITY_GROUP_RULE" ] || return 1
	local RULE_ID="$(jq -r .id<<<"$VPC_SECURITY_GROUP_RULE")" && [ ! -z "$RULE_ID" ] || return 1
    [ ! -z "$(checked_api2 '.SecurityGroupRule.Id' GET "/vpc?Version=2017-11-30&Action=DeleteSecurityGroupRule&Id=$RULE_ID")" ] && {
		echo "[INFO] VPC security group rule '$RULE_ID' deleted." >&2
        return 0
    }
	return 1
}

