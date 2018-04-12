#! /bin/bash

INSTANCE_TYPE_SPEC_PRESETS='{
  "nvm.n1.small2": {series: 1, type: 1, cpu: 1, memory: "2G"},
  "nvm.n1.small4": {series: 1, type: 1, cpu: 1, memory: "4G"},
  "nvm.n1.medium2": {series: 1, type: 1, cpu: 2, memory: "2G"},
  "nvm.n1.medium4": {series: 1, type: 1, cpu: 2, memory: "4G"},
  "nvm.n1.medium8": {series: 1, type: 1, cpu: 2, memory: "8G"},
  "nvm.n1.medium8": {series: 1, type: 1, cpu: 2, memory: "8G"},
  "nvm.n1.large4": {series: 1, type: 1, cpu: 4, memory: "4G"},
  "nvm.n1.large8": {series: 1, type: 1, cpu: 4, memory: "8G"},
  "nvm.n1.large16": {series: 1, type: 1, cpu: 4, memory: "16G"},
  "nvm.n1.xlarge8": {series: 1, type: 1, cpu: 8, memory: "8G"},
  "nvm.n1.xlarge16": {series: 1, type: 1, cpu: 8, memory: "16G"},
  "nvm.n1.xlarge32": {series: 1, type: 1, cpu: 8, memory: "32G"},
  "nvm.n1.2xlarge32": {series: 1, type: 1, cpu: 16, memory: "32G"},
  "nvm.n1.2xlarge64": {series: 1, type: 1, cpu: 16, memory: "64G"},
  "nvm.n1.4xlarge64": {series: 1, type: 1, cpu: 32, memory: "64G"},
  "nvm.n1.4xlarge128": {series: 1, type: 1, cpu: 32, memory: "128G"},

  "nvm.n2.small2": {series: 2, type: 1, cpu: 1, memory: "2G"},
  "nvm.n2.small4": {series: 2, type: 1, cpu: 1, memory: "4G"},
  "nvm.n2.medium2": {series: 2, type: 1, cpu: 2, memory: "2G"},
  "nvm.n2.medium4": {series: 2, type: 1, cpu: 2, memory: "4G"},
  "nvm.n2.medium8": {series: 2, type: 1, cpu: 2, memory: "8G"},
  "nvm.n2.medium8": {series: 2, type: 1, cpu: 2, memory: "8G"},
  "nvm.n2.large4": {series: 2, type: 1, cpu: 4, memory: "4G"},
  "nvm.n2.large8": {series: 2, type: 1, cpu: 4, memory: "8G"},
  "nvm.n2.large16": {series: 2, type: 1, cpu: 4, memory: "16G"},
  "nvm.n2.xlarge8": {series: 2, type: 1, cpu: 8, memory: "8G"},
  "nvm.n2.xlarge16": {series: 2, type: 1, cpu: 8, memory: "16G"},
  "nvm.n2.xlarge32": {series: 2, type: 1, cpu: 8, memory: "32G"},
  "nvm.n2.2xlarge32": {series: 2, type: 1, cpu: 16, memory: "32G"},
  "nvm.n2.2xlarge64": {series: 2, type: 1, cpu: 16, memory: "64G"},
  "nvm.n2.4xlarge64": {series: 2, type: 1, cpu: 32, memory: "64G"},
  "nvm.n2.4xlarge128": {series: 2, type: 1, cpu: 32, memory: "128G"},

  "nvm.e2.large8": {series: 2, type: 2, cpu: 4, memory: "8G"},
  "nvm.e2.large16": {series: 2, type: 2, cpu: 4, memory: "16G"},
  "nvm.e2.xlarge16": {series: 2, type: 2, cpu: 8, memory: "16G"},
  "nvm.e2.xlarge32": {series: 2, type: 2, cpu: 8, memory: "32G"},
  "nvm.e2.2xlarge32": {series: 2, type: 2, cpu: 16, memory: "32G"},
  "nvm.e2.2xlarge64": {series: 2, type: 2, cpu: 16, memory: "64G"},
  "nvm.e2.4xlarge64": {series: 2, type: 2, cpu: 32, memory: "64G"},
  "nvm.e2.4xlarge128": {series: 2, type: 2, cpu: 32, memory: "128G"}
}'

instance_type_normalize(){
	local INSTANCE_TYPE="$1" FILTER="${2:-.}" STAGE="$NPC_STAGE/instance_type.specs"
	[ ! -z "$INSTANCE_TYPE" ] || {
		echo "[ERROR] instance_type required" >&2
		return 1
	}
	( exec 100>$STAGE.lock && flock 100
		[ ! -f $STAGE ] && jq "$INSTANCE_TYPE_SPEC_PRESETS"' + (.npc_instance_type_specs//{})' $NPC_STAGE/.input >$STAGE
	)
	local SPEC_NAME="$(jq -r '.spec//empty'<<<"$INSTANCE_TYPE")" && [ ! -z "$SPEC_NAME" ] || {
		SPEC_NAME="$(jq -r --argjson q "$INSTANCE_TYPE" 'to_entries[] | select(
			(.value.series//1|tostring) == ($q.series//1|tostring) 
			and (.value.type//1|tostring) == ($q.type//1|tostring)
			and (.value.cpu|tostring) == ($q.cpu|tostring)
			and .value.memory == (($q.memory//"0G")|sub("[Gg]$"; "G"))
			and (.value.ssd//"20G") == (($q.ssd//"20G")|sub("[Gg]$"; "G"))
			) | .key' $STAGE)" && [ ! -z "$SPEC_NAME" ] || {
				echo "[ERROR] instance_type.spec required - '$INSTANCE_TYPE'" >&2
				return 1
			}
	}
	local SPEC_TYPE="$(export SPEC_NAME; jq -c '.[env.SPEC_NAME]//empty | . + { spec: env.SPEC_NAME }' $STAGE)"
	[ ! -z "$SPEC_TYPE" ] || echo "[WARN] instance_type.spec '$SPEC_NAME' not explicit declared" >&2
	jq -nc "$INSTANCE_TYPE + ${SPEC_TYPE:-{\}} | $FILTER"
}
