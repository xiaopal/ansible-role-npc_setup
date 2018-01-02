#! /bin/bash

setup_resources "vpc_routes"

# - route: '1.1.1.6/32 @default @corp-vpc'
#   via_instance: sample
init_vpc_routes(){
	local INPUT="$1" STAGE="$2" VPC VPC_NAME \
		ROUTE_TABLE ROUTE_TABLE_NAME ROUTE_TABLE_ID 
	jq_check '.npc_vpc_routes|arrays' $INPUT || return 0
    (jq -c '.npc_vpc_routes//[]' $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='route' \
		expand_resources 'map(select(.route)
			| . + (.route | capture("(?<cidr_addr>\\d+\\.\\d+\\.\\d+\\.\\d+)(?:/(?<cidr_mask>\\d+))?(?:@(?<route_table>[\\w\\-]+)@(?<vpc>[\\w\\-]+))?"))
			| select(.route_table and .vpc)
			| . + if .cidr_addr then {cidr: "\(.cidr_addr)/\(.cidr_mask//"32")"} else {} end
            | select(.cidr))' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map("\(.route_table) \(.vpc)")|unique[]' $STAGE.expand | while read -r ROUTE_TABLE VPC _; do
		( export ROUTE_TABLE VPC VPC_NAME="$(vpc_networks_lookup "$VPC" '.Name')"
			[ ! -z "$VPC_NAME" ] && vpc_route_tables_lookup "$ROUTE_TABLE" "$VPC" '"\(env.ROUTE_TABLE) \(env.VPC) \(.Id) \(.Name) \(env.VPC_NAME)"' \
				|| echo "$ROUTE_TABLE $VPC"
		)
        done | sort -u | while read -r ROUTE_TABLE VPC ROUTE_TABLE_ID ROUTE_TABLE_NAME VPC_NAME; do
        [ ! -z "$ROUTE_TABLE_ID" ] || { ROUTE_TABLE="$ROUTE_TABLE" VPC="$VPC" \
            jq_check '.[]|select(.vpc == env.VPC and .route_table == env.ROUTE_TABLE and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export ROUTE_TABLE VPC ROUTE_TABLE_ID ROUTE_TABLE_NAME VPC_NAME
            LOAD_FILTER='{
                id: .Id,
                cidr: .DestinationCidrBlock,
                via_type: .InstanceType,
                via_id: .InstanceId
            }'
            ROUTE_FILTER='.+{
                name: "\(.cidr)@\(env.ROUTE_TABLE_NAME)@\(env.VPC_NAME)",
                route_table_id: env.ROUTE_TABLE_ID
            }'
            jq -c "map(select(.vpc == env.VPC and .route_table == env.ROUTE_TABLE)|$ROUTE_FILTER)" $STAGE.expand >>$STAGE.init0 
            checked_api2 ".Routes//empty|map($LOAD_FILTER|$ROUTE_FILTER)" \
                GET "/vpc?Version=2017-11-30&Action=ListRoute&RouteTableId=$ROUTE_TABLE_ID&Limit=100" >>$STAGE.init1
        )
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
        '. + {update: false}' || return 1
	return 0
}

vpc_routes_create(){
	local VPC_ROUTE="$1" RESULT="$2" CTX="$3" VIA_TYPE VIA_ID && [ ! -z "$VPC_ROUTE" ] || return 1
    local VIA_INSTANCE="$(jq -r '.via_instance'<<<"$VPC_ROUTE")" \
        && [ ! -z "$VIA_INSTANCE" ] && {
        VIA_TYPE="NWS"
        VIA_ID="$(instances_lookup "$VIA_INSTANCE")" && [ ! -z "$VIA_ID" ] || return 1
    }
    [ ! -z "$VIA_TYPE" ] && [ ! -z "$VIA_ID" ] || {
        echo '[ERROR] via-* required.' >&2
        return 1
    }
	local CREATE_ROUTE="$(export VIA_TYPE VIA_ID; jq -c '{
		RouteTableId: .route_table_id,
		DestinationCidrBlock: .cidr,
		InstanceType: env.VIA_TYPE,
		InstanceId: env.VIA_ID
	}|with_entries(select(.value))'<<<"$VPC_ROUTE")"
    local ROUTE_ID="$(NPC_API_LOCK="$NPC_STAGE/vpc_routes.create_lock" checked_api2 '.Route.Id' POST "/vpc?Version=2017-11-30&Action=CreateRoute" "$CREATE_ROUTE")" \
        && [ ! -z "$ROUTE_ID" ] && {
			echo "[INFO] VPC route '$ROUTE_ID' created." >&2
			return 0
        }
	return 1
}

vpc_routes_destroy(){
	local VPC_ROUTE="$1" RESULT="$2" CTX="$3" && [ ! -z "$VPC_ROUTE" ] || return 1
	local ROUTE_ID="$(jq -r .id<<<"$VPC_ROUTE")" && [ ! -z "$ROUTE_ID" ] || return 1
    [ ! -z "$(checked_api2 '.Route.Id' GET "/vpc?Version=2017-11-30&Action=DeleteRoute&Id=$ROUTE_ID")" ] && {
		echo "[INFO] VPC route '$ROUTE_ID' deleted." >&2
        return 0
    }
	return 1
}

