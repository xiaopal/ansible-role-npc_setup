#! /bin/bash

setup_resources "dns_record_sets"
JQ_DNS_RECORD_SETS='.npc_dns_record_sets[]?, ('"$JQ_DNS_ZONES"'|select(.present != false) | . as $zone | .record_sets[]? | .record_set |= "\(.)@\($zone.name)")'

init_dns_record_sets(){
	local INPUT="$1" STAGE="$2" DNS_ZONE DNS_ZONE_ID
	jq_check "$JQ_DNS_RECORD_SETS" $INPUT || return 0
    (jq -c "[ $JQ_DNS_RECORD_SETS ]" $INPUT || >>$STAGE.error) | EXPAND_KEY_ATTR='record_set' \
		expand_resources 'map(select(.record_set)
			| . + (.record_set | capture("(?:(?<type>\\w+),)?(?<record_set_name>[\\w\\-\\.]+)(?:,(?<ttl>\\d+))?(?:@(?<dns_zone>[\\w\\-\\.]+))?")|with_entries(select(.value))) 
			| select(.record_set_name and .dns_zone)
			| . + { type: (.type//"A"|ascii_upcase), record_set_name: (.record_set_name|sub("\\.*$"; ".")) } )' >$STAGE.expand
	>$STAGE.init0;  >$STAGE.init1; 	
    jq -r 'map(.dns_zone//empty)|unique[]' $STAGE.expand | while read -r DNS_ZONE _; do
            DNS_ZONE="$DNS_ZONE" dns_zones_lookup "$DNS_ZONE" '"\(env.DNS_ZONE) \(.HostedZoneId)"' || echo "$DNS_ZONE"
        done | sort -u | while read -r DNS_ZONE DNS_ZONE_ID; do
        [ ! -z "$DNS_ZONE_ID" ] || { DNS_ZONE="$DNS_ZONE" \
            jq_check '.[]|select(.dns_zone == env.DNS_ZONE and .present != false)' $STAGE.expand || continue
            >>$STAGE.error; break
        }
        ( export DNS_ZONE DNS_ZONE_ID
            local LOAD_FILTER='{
                id: .ResourceRecordSetId,
                record_set_name: .Name,
                type: .Type,
                actual_ttl: .TTL,
				actual_records: .ResourceRecords 
            }' RECORD_SET_FILTER='.+{
                name: "\(.type),\(.record_set_name)@\(env.DNS_ZONE_ID)",
                dns_zone_id: env.DNS_ZONE_ID
            }'
            jq -c "map(select(.dns_zone == env.DNS_ZONE)|$RECORD_SET_FILTER)" $STAGE.expand >>$STAGE.init0 || exit 1

			local LIMIT=100 OFFSET=0 COUNT="$(checked_api2 ".ResourceRecordSetCount" \
                GET "/dns?Version=2017-12-12&Action=GetResourceRecordSetCount&HostedZoneId=$DNS_ZONE_ID")" && [ ! -z "$COUNT" ] || exit 1
			while (( OFFSET < COUNT )); do
				checked_api2 ".ResourceRecordSets//empty|map($LOAD_FILTER|$RECORD_SET_FILTER)" \
					GET "/dns?Version=2017-12-12&Action=ListResourceRecordSets&HostedZoneId=$DNS_ZONE_ID&Offset=$OFFSET&Limit=$LIMIT" >>$STAGE.init1
				(( OFFSET += LIMIT ))
			done
        ) || { >>$STAGE.error; break; }
    done
    [ ! -f $STAGE.error ] && plan_resources "$STAGE" \
        <(jq -sc 'flatten' $STAGE.init0) <(jq -sc 'flatten' $STAGE.init1) \
			' . + (if .ttl then {ttl: (.ttl | tonumber)} else {} end)
			| . + (if (.create or .update) and (.records | not) and (.present_records or .absent_records) then
					{ records: ((.actual_records//[]) 
						- ((.absent_records//[]) + (.present_records//[]) | map(., sub("\\.*$"; ".")))
						+ (.present_records//[])) }
				else {} end) 
			| . + (if (.create or .update) and (.records | length == 0) then { present: false, destroy: .update, create: false, update: false} else {} end)
			| . + {update: (.update and (
				(.records and ( 
					(.actual_records|length) == (.records|length) and 
					(.actual_records - (.records|map(., sub("\\.*$"; "."))) + .records|sort) == (.records|sort)
					| not ) ) or 
				(.ttl and .ttl != .actual_ttl))) }' || return 1
	return 0
}

dns_record_sets_create(){
	local DNS_RECORD_SET="$1" RESULT="$2" CTX="$3" && [ ! -z "$DNS_RECORD_SET" ] || return 1
	local CREATE_RECORD_SET="$(jq -c '{
			Name: .record_set_name,
			Type: .type,
			TTL: (.ttl//3600),
			ResourceRecords: .records
		}|with_entries(select(.value))'<<<"$DNS_RECORD_SET")"
    local CREATE_ID="$(NPC_API_LOCK="$NPC_STAGE/dns_record_sets.create_lock" checked_api2 '.ResourceRecordSet.ResourceRecordSetId' \
			POST "/dns?Version=2017-12-12&Action=CreateResourceRecordSet&HostedZoneId=$(jq -r .dns_zone_id<<<"$DNS_RECORD_SET")" "$CREATE_RECORD_SET")" \
        && [ ! -z "$CREATE_ID" ] && {
			echo "[INFO] DNS record set '$CREATE_ID($(jq -r .record_set_name<<<"$DNS_RECORD_SET"))' created." >&2
			return 0
        }
	echo "[ERROR] Failed to create DNS record set: $CREATE_RECORD_SET" >&2
	return 1
}

dns_record_sets_update(){
	local DNS_RECORD_SET="$1" RESULT="$2" CTX="$3" && [ ! -z "$DNS_RECORD_SET" ] || return 1
	local UPDATE_ID="$(jq -r .id<<<"$DNS_RECORD_SET")" && [ ! -z "$UPDATE_ID" ] || return 1
	local UPDATE_RECORD_SET="$(jq -c '{
			TTL: (.ttl//.actual_ttl),
			ResourceRecords: (.records//.actual_records)
		}|with_entries(select(.value))'<<<"$DNS_RECORD_SET")"
    [ ! -z "$(checked_api2 '.ResourceRecordSet.ResourceRecordSetId' POST "/dns?Version=2017-12-12&Action=UpdateResourceRecordSet&ResourceRecordSetId=$UPDATE_ID" "$UPDATE_RECORD_SET")" ] && {
		echo "[INFO] DNS record set '$UPDATE_ID($(jq -r .record_set_name<<<"$DNS_RECORD_SET"))' updated." >&2
        return 0
    }
	echo "[ERROR] Failed to update DNS record set: $UPDATE_RECORD_SET" >&2
	return 1
}

dns_record_sets_destroy(){
	local DNS_RECORD_SET="$1" RESULT="$2" CTX="$3" && [ ! -z "$DNS_RECORD_SET" ] || return 1
	local DESTROY_ID="$(jq -r .id<<<"$DNS_RECORD_SET")" && [ ! -z "$DESTROY_ID" ] || return 1
    [ ! -z "$(checked_api2 '.ResourceRecordSet.ResourceRecordSetId' GET "/dns?Version=2017-12-12&Action=DeleteResourceRecordSet&ResourceRecordSetId=$DESTROY_ID")" ] && {
		echo "[INFO] DNS record set '$DESTROY_ID($(jq -r .record_set_name<<<"$DNS_RECORD_SET"))' deleted." >&2
        return 0
    }
	echo "[ERROR] Failed to delete DNS record set: $DESTROY_ID($(jq -r .record_set_name<<<"$DNS_RECORD_SET"))" >&2
	return 1
}
