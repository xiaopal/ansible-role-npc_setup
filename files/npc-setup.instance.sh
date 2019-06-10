#! /bin/bash

setup_resources "instances"

MAPPER_PRE_LOAD_INSTANCE='{
        id: .InstanceId,
        name: .InstanceName,
        status: .Status,
        lan_ip: (.PrivateIpAddresses[0]),
        zone: (.Placement.ZoneId),

        inet_ip: (.PublicIpAddresses[0]//.EipAddress//false),
        corp_ip: (.PrivateIdcIpAddresses[0]//false),
        
        actual_volumes: (.InstanceId as $uuid |.AttachVolumes//[]|map({
            key:.DiskName,
            value:{
                id: .DiskId,
                name:.DiskName, 
                instance_id: $uuid,
# v2 api 不支持的特性
#               volume_uuid: .volumeId,
                device: .Device
            }
        })|from_entries),

        actual_wan_ip: (.PublicIpAddresses[0]//.EipAddress//false),
# v2 api 不支持的特性
#       actual_wan_id: (.public_port_id//false),
        actual_wan_capacity: (if .InternetMaxBandwidth then "\(.InternetMaxBandwidth|tonumber)M" else false end),
        actual_image: (.Image.ImageName),
        actual_type: { spec:.SpecType }
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
# 废弃 recreate 选项
#                   + if  .instance_type and .actual_type != .instance_type then
#                       {update: true, recreate: true}
#                   else {} end
#                   + if .instance_image and .actual_image != .instance_image then
#                       {update: true, recreate: true}
#                   else {} end
# load_instances 列表不返回 actual_volumes 无法提前判断是否需要更新, 需要总是 update_volumes
#                   + if .plan_volumes and (.plan_volumes|map(select(.mount or .unmount))|length>0) then
                    + if .plan_volumes then
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
    for IMAGE_TYPE in "Private" "Public"; do
        local STAGE="$NPC_STAGE/$IMAGE_TYPE"
        ( exec 100>$STAGE.lock && flock 100
            [ ! -f $STAGE ] && {
                npc api2 'json.Images' POST '/nvm?Action=DescribeImages&Version=2017-12-14&Limit=9999&Offset=0' \
                "$(export IMAGE_TYPE && jq -nc '{Filter: {ImageType: [env.IMAGE_TYPE]}}')" >$STAGE || rm -f $STAGE
            }
        )
        [ -f $STAGE ] && IMAGE_NAME="$IMAGE_NAME" \
            jq -re '(env.IMAGE_NAME | capture("^/(?<regex>.+)/(?<flags>[a-z]+)?$|^(?<text>.+)$")) as $lookup
                |map(select(
                    ($lookup.text and (.ImageName==$lookup.text or .ImageId==$lookup.text)) or
                    ($lookup.regex and (.ImageName | test($lookup.regex;$lookup.flags))) ))
                |.[0]//empty|.ImageId//empty' $STAGE    \
            && return 0
    done
    echo "[ERROR] instance_image - '$IMAGE_NAME' not found" >&2
    return 1
}

instances_prepare(){
    local INSTANCE="$1" 
    jq -ce 'select(.prepared)'<<<"$INSTANCE" && return 0

    local IMAGE_ID INSTANCE_TYPE_CONFIG="{}" SSH_KEYS_CONFIG="{}"
    jq_check '.create or .recreate'<<<"$INSTANCE" && {
        local IMAGE_NAME="$(jq -r '.instance_image//.default_instance_image//empty'<<<"$INSTANCE")" && [ ! -z "$IMAGE_NAME" ] || {
            echo '[ERROR] instance_image required.' >&2
            return 1
        }
        IMAGE_ID="$(instances_lookup_image "$IMAGE_NAME")" && [ ! -z "$IMAGE_ID" ] || return 1

        INSTANCE_TYPE_CONFIG="$(instance_type_normalize "$(jq -c '.instance_type//empty'<<<"$INSTANCE")" '{instance_type: .}')"
        [ ! -z "$INSTANCE_TYPE_CONFIG" ] || return 1

        jq -r '.ssh_keys//empty|.[]'<<<"$INSTANCE" | check_ssh_keys && \
        SSH_KEYS_CONFIG="$(jq -r '.ssh_keys//empty|.[]'<<<"$INSTANCE" | check_ssh_keys --output '.' | jq -sc '{checked_ssh_keys: .}')" && \
        [ ! -z "$SSH_KEYS_CONFIG" ] || return 1
    }
    
    local PLAN_VOLUMES PLAN_VOLUMES_CONFIG='{}'
    jq_check '.plan_volumes'<<<"$INSTANCE" && {
        while read -r VOLUME; do
            local VOLUME_NAME="$(jq -r '.name'<<<"$VOLUME")"
            local VOLUME_ID="$(volumes_lookup "$VOLUME_NAME" '.id')" && [ ! -z "$VOLUME_ID" ] || return 1
            [ ! -z "$PLAN_VOLUMES" ] || PLAN_VOLUMES="$(jq -c '.plan_volumes//empty'<<<"$INSTANCE")"
            PLAN_VOLUMES="$(export VOLUME_NAME VOLUME_ID; jq -c '.[env.VOLUME_NAME] |= . + {id: env.VOLUME_ID}'<<<"$PLAN_VOLUMES")"
        done < <(jq -c '.plan_volumes[]|select(.present and (.id|not))'<<<"$INSTANCE")
        [ ! -z "$PLAN_VOLUMES" ] && PLAN_VOLUMES_CONFIG="$(jq -c '{plan_volumes: .}'<<<"$PLAN_VOLUMES")"
    }

    local WAN_IP
    jq_check '.plan_wan_ip and .plan_wan_ip.bind and (.plan_wan_ip.rebind|not)'<<<"$INSTANCE" && {
# deprecated @ 2019-02-21
#       WAN_IP="$(instances_acquire_ip "$(jq -r '.wan_ip'<<<"$INSTANCE")")" && [ ! -z "$WAN_IP" ] || return 1
        echo "[ERROR] acquire wan ip  not supported" >&2
        return 1        
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
    }'" +$INSTANCE_TYPE_CONFIG +$PLAN_VOLUMES_CONFIG +$WAN_CONFIG +$VPC_CONFIG +$SSH_KEYS_CONFIG"<<<"$INSTANCE" && return 0 || return 1
}

instances_wait_instance(){
    local INSTANCE INSTANCE_ID="$1" CTX="$2" && shift && shift && [ ! -z "$INSTANCE_ID" ] || return 1
    local ARGS=("$@") && (( ${#ARGS[@]} > 0)) || ARGS=('select(.)') 
    while action_check_continue "$CTX"; do
        INSTANCE="$(npc api2 "json|$MAPPER_PRE_LOAD_INSTANCE" GET "/nvm?Action=DescribeInstance&Version=2017-12-14&InstanceId=$INSTANCE_ID")" && [ ! -z "$INSTANCE" ] && {
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
    jq_check '.vpc_network'<<<"$INSTANCE" || {
# 废弃非 vpc 主机创建 @ 2019-02-21
        echo "[ERROR] create non-vpc instance not supported" >&2
        return 1
    }
    while true; do
        local RESPONSE="$(api2_create_instance "$INSTANCE" "$CTX")" && [ ! -z "$RESPONSE" ] || return 1
        local INSTANCE_ID="$(jq -r '.id//empty'<<<"$RESPONSE")" && [ ! -z "$INSTANCE_ID" ] \
            && instances_wait_instance "$INSTANCE_ID" "$CTX" \
            && {
                echo "[INFO] instance '$INSTANCE_ID' created." >&2 
# 废弃创建后 wan 和 volumes 更新 @ 2019-02-21                
#               [ ! -z "$API2_CREATE" ] || {
#                   instances_update_volumes "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
#                   instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
#               }
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

api2_create_instance(){
    local INSTANCE="$1" CTX="$2" PLAN_VOLUME

    jq_check '.plan_volumes'<<<"$INSTANCE" && while read -r PLAN_VOLUME; do
        local VOLUME_NAME="$(jq -r '.name'<<<"$PLAN_VOLUME")" VOLUME_ID="$(jq -r '.id'<<<"$PLAN_VOLUME")"
        [ ! -z "$VOLUME_NAME" ] && [ ! -z "$VOLUME_ID" ] || {
            echo "[ERROR] invalid instance volume '$PLAN_VOLUME'." >&2 
            return 1
        }
        local VOLUME="$(volumes_wait_status "$VOLUME_ID" "$CTX" '.')" && [ ! -z "$VOLUME" ] || return 1
        jq_check '.available'<<<"$VOLUME" || {
            echo "[ERROR] volume '$VOLUME_NAME' not available" >&2 
            return 1
        }
    done < <(jq -c '.plan_volumes[]|select(.present)'<<<"$INSTANCE")
    
    local CREATE_INSTANCE="$(jq -c '{
            PayType: "PostPaid",
            InstanceName: .name,
            ImageId: .instance_image_id,
            SpecType: .instance_type.spec,
            KeyPairNames: (.checked_ssh_keys|map({name:.name, fingerprint: .fingerprint})),
            Placement: ({
                ZoneId: (.zone//.az)
                }|with_entries(select(.value))),
            VirtualPrivateCloud: ({
                VpcId: .vpc_network,
                SubnetId: (if .vpc_network then .vpc_subnet else false end)
                }|with_entries(select(.value))),
            SecurityGroupIds: (if .vpc_network then [.vpc_security_group] else [] end),
            AssociatePublicIpAddress: (if .vpc_network and .vpc_inet then true else false end),
            InternetMaxBandwidth: (if .vpc_network and .vpc_inet then
                    (.vpc_inet_capacity//"1M"|sub("[Mm]$"; "")|tonumber)
                else false end),
            NetworkChargeType: (if .vpc_network and .vpc_inet then "TRAFFIC" else false end),
            AssociatePrivateIdcIpAddress: (if .vpc_network and .vpc_corp then true else false end),
            Personality: (.user_data//{} | to_entries | map({ 
                Path: .key, 
                Contents: .value 
                }) | select(length > 0) // false),
            DataVolumes: (.data_volumes//[] | map({ 
                VolumeType: (.type//"EPHEMERAL"), 
                VolumeSize: (.capacity|sub("[Gg]$"; "")|tonumber) 
                }) | select(length > 0) // false),
            AttachVolumeIds: (if .plan_volumes then (.plan_volumes|map(select(.present)|.id)) else false end),
            Description: .description
        } | with_entries(select(.value))'<<<"$INSTANCE")"
    (
        export INSTANCE_ID="$(NPC_API_LOCK="$NPC_STAGE/instances.create_lock" checked_api2 '.Instances//[]|.[0]//empty' POST "/nvm?Action=CreateInstance&Version=2017-12-14" "$CREATE_INSTANCE")" \
            && [ ! -z "$INSTANCE_ID" ] && jq -nr '{ id: env.INSTANCE_ID }'
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
# 废弃 wan 更新 @ 2019-02-21                
#       instances_update_wan "$INSTANCE_ID" "$INSTANCE" "$CTX" || return 1
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
    checked_api2 GET "/nvm?Action=DeleteInstance&Version=2017-12-14&InstanceId=$INSTANCE_ID" && {
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
                npc api2 'json.Instances[]' POST "/nvm?Action=DescribeInstanceList&Version=2017-12-14&Limit=$PAGE_SIZE&Offset=$(( (FORK-1) * PAGE_SIZE))" '{}' >"$FORKS/$FORK.load"
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
     } < <(npc api2 "json|(.TotalCount/$PAGE_SIZE|-.|floor|-.),.Instances[]" \
               POST "/nvm?Action=DescribeInstanceList&Version=2017-12-14&Limit=$PAGE_SIZE&Offset=0" '{}') \
        | jq -sc '.'
    wait; [ ! -z "$FORKS" ] && rm -fr "$FORKS"
    return 0
}

instances_lookup(){
    local INSTANCE="$1" FILTER="${2:-.id}" STAGE="$NPC_STAGE/${INSTANCES_LOOKUP_KEY:-instances}.lookup"
    ( exec 100>$STAGE.lock && flock 100
        [ ! -f $STAGE ] && {
            load_instances '{
                id: .InstanceId,
                name: .InstanceName,
                lan_ip: (.PrivateIpAddresses[0]),
                zone: (.Placement.ZoneId),
                inet_ip: (.PublicIpAddresses[0]//.EipAddress//false),
                corp_ip: (.PrivateIdcIpAddresses[0]//false)
            }' >$STAGE || rm -f $STAGE
        }
    )
    [ ! -z "$INSTANCE" ] && [ -f $STAGE ] && INSTANCE="$INSTANCE" \
        jq_check --stdout '.[]|select(.id == env.INSTANCE or .name == env.INSTANCE)|'"$FILTER" $STAGE   \
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