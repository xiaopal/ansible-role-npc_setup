#! /bin/bash

# setup_resources "vpc_networks"
# setup_resources "vpc_subnets"
# setup_resources "npc_vpc_security_groups"
# setup_resources "npc_vpc_route_tables"

# vpc_networks_lookup(){
# 	local NETWORK="$1" FILTER="$2" STAGE="$NPC_STAGE/vpc_networks.lookup"
# 	( exec 100>$STAGE.lock && flock 100
# 		[ ! -f $STAGE ] && {
# 			load_volumes >$STAGE || rm -f $STAGE
# 		}
# 	)
# 	[ -f $STAGE ] && VOLUME_NAME="$VOLUME_NAME" \
# 		jq_check --stdout ".[]|select(.name==env.VOLUME_NAME)${FILTER:+|$FILTER}" $STAGE	\
# 		&& return 0
# 	echo "[ERROR] volume '$VOLUME_NAME' not found" >&2
# 	return 1
# }
