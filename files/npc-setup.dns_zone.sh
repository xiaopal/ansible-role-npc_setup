#! /bin/bash

setup_resources "dns_zones"

dns_zones_lookup(){
	local DNS_ZONE="$1" FILTER="${2:-.HostedZoneId}" STAGE="$NPC_STAGE/dns_zones.lookup"
 	( exec 100>$STAGE.lock && flock 100
 		[ ! -f $STAGE ] && {
 			checked_api2 '.HostedZones' GET '/dns?Version=2017-12-12&Action=ListHostedZones&Limit=200' >$STAGE || rm -f $STAGE
 		}
 	)
 	[ ! -z "$DNS_ZONE" ] && [ -f $STAGE ] && DNS_ZONE="$DNS_ZONE" \
 		jq_check --stdout '.[]|select(.HostedZoneId == env.DNS_ZONE or .Name == (env.DNS_ZONE|sub("\\.*$"; ".")))|'"$FILTER" $STAGE	\
 		&& return 0
 	echo "[ERROR] DNS Zone '$DNS_ZONE' not found" >&2
 	return 1
 }

init_dns_zones(){
	local INPUT="$1" STAGE="$2" JQ_DNS_ZONES='.npc_dns_zones[]?' LOAD_FILTER='{
		name: .Name,
		id: .HostedZoneId
	}'
	jq_check "$JQ_DNS_ZONES" $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c "[ $JQ_DNS_ZONES ]"'|map(.name |= sub("\\.*$"; "."))' $INPUT || >>$STAGE.error) \
			<(checked_api2 ".HostedZones//empty|map($LOAD_FILTER)" \
                GET '/dns?Version=2017-12-12&Action=ListHostedZones&Limit=200' || >>$STAGE.error) \
			'. + {update: false}' || return 1
	}
	return 0
}

dns_zones_create(){
	local DNS_ZONE="$1" RESULT="$2" CTX="$3" && [ ! -z "$DNS_ZONE" ] || return 1
    local VPC_NETWORK="$(jq -r '.vpc_network//.vpc//empty'<<<"$DNS_ZONE")" VPC_CONFIG='{}'
	[ ! -z "$VPC_NETWORK" ] && {
        VPC_NETWORK="$(vpc_networks_lookup "$VPC_NETWORK")" && [ ! -z "$VPC_NETWORK" ] || return 1
        VPC_CONFIG="$(export VPC_NETWORK VPC_REGION="${NPC_API_REGION:-cn-east-1}" && jq -c '{ 
            VpcId: env.VPC_NETWORK, 
            VpcRegion: env.VPC_REGION, 
            HostedZoneVpcAssociationComment: (.vpc_description//.vpc_comment)
        } | with_entries(select(.value))'<<<"$DNS_ZONE")"
	}
	local CREATE_DNS_ZONE="$(jq -r --argjson vpc "$VPC_CONFIG" '{
		Name: .name,
        IsPrivateZone: true,
        Policy: (if .fallthrough then "fallthrough" else "default" end),
		Comment: (.description//.comment)
	} + $vpc | to_entries | map( select(.value) | "\(.key)=\(.value)" ) | join("&")'<<<"$DNS_ZONE")"
    local DNS_ZONE_ID="$(NPC_API_LOCK="$NPC_STAGE/dns_zones.create_lock" checked_api2 '.HostedZone.HostedZoneId' GET "/dns?Version=2017-12-12&Action=CreateHostedZone&$CREATE_DNS_ZONE")" \
        && [ ! -z "$DNS_ZONE_ID" ] && {
			echo "[INFO] DNS zone '$DNS_ZONE_ID' created." >&2
			return 0
        }
	return 1
}

dns_zones_destroy(){
	local DNS_ZONE="$1" RESULT="$2" CTX="$3" && [ ! -z "$DNS_ZONE" ] || return 1
	local DNS_ZONE_ID="$(jq -r .id<<<"$DNS_ZONE")" && [ ! -z "$DNS_ZONE_ID" ] || return 1
    [ ! -z "$(checked_api2 '.HostedZone.HostedZoneId' GET "/dns?Version=2017-12-12&Action=DeleteHostedZone&HostedZoneId=$DNS_ZONE_ID")" ] && {
        echo "[INFO] DNS zone '$DNS_ZONE_ID' deleted." >&2
        return 0
    }
	return 1
}
