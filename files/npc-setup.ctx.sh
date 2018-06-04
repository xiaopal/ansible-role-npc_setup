#! /bin/bash

jq_check(){
	local ARGS=() ARG OUTPUT
	while ARG="$1" && shift; do
		case "$ARG" in
		--out|--output)
			OUTPUT="$1" && shift
			;;
		--stdout)
			OUTPUT="/dev/fd/1"
			;;
		--stderr)
			OUTPUT="/dev/fd/2"
			;;
		*)
			ARGS=("${ARGS[@]}" "$ARG")
			;;
		esac
	done
	local CHECK_RESULT="$(jq "${ARGS[@]}")" && [ ! -z "$CHECK_RESULT" ] \
		&& jq -cre 'select(.)'<<<"$CHECK_RESULT" >${OUTPUT:-/dev/null} && return 0
	[ ! -z "$OUTPUT" ] && [ -f "$OUTPUT" ] && rm -f "$OUTPUT"
	return 1
}

expand_resources(){
	local LINE KEY FILTER="${1:-.}" KEY_ATTR="${EXPAND_KEY_ATTR:-name}"
	dump_str_vals(){
		local ARG; for ARG in "$@"; do echo "$# $ARG"; done
	}
	while read -r LINE; do
		local KEYS=($(eval "echo $(jq -r ".$KEY_ATTR"'|gsub("^\\*\\:|[\\s\\$]"; "")'<<<"$LINE")")) KEY_INDEX=0
		for KEY in "${KEYS[@]}"; do
			[ ! -z "$KEY" ] || continue
			while read -r STM_LINE; do 
				local STM_VAL_JQ STM_VAL STM_VAL_COUNT STM_VAL_INDEX=0
				if jq_check 'length>1 and (.[1]|strings|startswith("*:"))'<<<"$STM_LINE"; then
					STM_VAL_JQ='.[1]|gsub("^\\*\\:|[\\s\\$]"; "")'
				elif jq_check 'length>1 and (.[1]|strings|startswith("@:"))'<<<"$STM_LINE"; then
					STM_VAL_JQ='.[1]|gsub("^\\@\\:"; "")|gsub("(?<c>[\\s\\$\\*])";"\\\(.c)")'
				else
					echo "$STM_LINE" && continue
				fi
				while read -r STM_VAL_COUNT STM_VAL; do
					(( STM_VAL_INDEX++ == KEY_INDEX % STM_VAL_COUNT )) \
						&& STM_VAL="$STM_VAL" jq -c '[.[0],env.STM_VAL]' <<<"$STM_LINE"
				done < <(eval dump_str_vals $(jq -r "$STM_VAL_JQ"<<<"$STM_LINE"))
			done < <(KEY="$KEY" jq --argjson index "$((KEY_INDEX))" -c ". + {$KEY_ATTR:env.KEY, ${KEY_ATTR}_index:\$index}|tostream"<<<"$LINE") \
				| jq -s 'fromstream(.[])'; ((KEY_INDEX++))
		done
	done < <(jq -c 'arrays[]') | jq -sc "$FILTER"
}

plan_resources(){
	local STAGE="$1" INPUT_EXPECTED="$2" INPUT_ACTUAL="$3" STAGE_MAPPER="$4"
	(jq -e 'arrays' $INPUT_EXPECTED || >>$STAGE.error) \
		| EXPAND_KEY_ATTR='name' expand_resources 'map({ key:.name, value:. }) | from_entries' >$STAGE.expected \
		&& [ ! -f $STAGE.error ] && jq_check 'objects' $STAGE.expected \
		&& jq -c 'arrays| map({ key:.name, value:. }) | from_entries' $INPUT_ACTUAL >$STAGE.actual \
		&& [ ! -f $STAGE.error ] && jq_check 'objects' $STAGE.actual \
		|| {
			rm -f $STAGE.*
			return 1
		}
	jq -sce '(.[0] | map_values({
				present: true,
				actual_present: false
			} + .)) * (.[1] | map_values(. + {
				actual_present: true
			})) 
		| map_values(. + {
			create: (.present and (.actual_present|not)),
			update: (.present and .actual_present),
			destroy : (.present == false and .actual_present),
			absent : (.present == null and .actual_present)
		}'"${STAGE_MAPPER:+| $STAGE_MAPPER}"')' $STAGE.expected $STAGE.actual >$STAGE \
		&& rm -f $STAGE.* || return 1
	jq -ce '.[]|select(.error and ((.absent or (.destroy and .force_destroy))|not))|.error' $STAGE >&2 && return 1
	jq -ce '.[]|select(.absent)' $STAGE > $STAGE.omit || rm -f $STAGE.omit
	jq -ce '.[]|select(.create)' $STAGE > $STAGE.creating || rm -f $STAGE.creating
	jq -ce '.[]|select(.update)' $STAGE > $STAGE.updating || rm -f $STAGE.updating
	jq -ce '.[]|select(.destroy)' $STAGE > $STAGE.destroying || rm -f $STAGE.destroying
}

report_resources(){
	local RESOURCES=() ARG REPORT_SUMMARY REPORT_FILTER
	while ARG="$1" && shift; do
		case "$ARG" in
		--summary)
			REPORT_SUMMARY='Y'
			;;
		--report)
			REPORT_FILTER="$1" && shift
			;;
		*)
			RESOURCES=("${RESOURCES[@]}" "$ARG")
			;;
		esac
	done
	
	do_report(){
		local RESOURCE="$1" STAGE="$NPC_STAGE/$1"
		local RESOURCE_FILTER="{$RESOURCE:([{key:.name,value:.}]|from_entries)}"
		[ -f $STAGE ] && {
			jq -nc "{ $RESOURCE:{} }"
			jq -c ".[]|select(.actual_present and (.create or .update or .destroy or .absent | not))|$RESOURCE_FILTER" $STAGE
			[ -f $STAGE.creating ] && if [ ! -f $STAGE.created ]; then
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{creating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.creating
			else
				jq -c '.+{change_action:"created"}|'"$RESOURCE_FILTER" $STAGE.created
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{created: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.created
			fi
			[ -f $STAGE.updating ] && if [ ! -f $STAGE.updated ]; then
				jq -c '.+{change_action:"updating"}|'"$RESOURCE_FILTER" $STAGE.updating
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{updating: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updating
			else
				jq -c '.+{change_action:"updated"}|'"$RESOURCE_FILTER" $STAGE.updated
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{updated: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.updated
			fi
			[ -f $STAGE.destroying ] && if [ ! -f $STAGE.destroyed ]; then
				jq -c '.+{change_action:"destroying"}|'"$RESOURCE_FILTER" $STAGE.destroying
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{destroying: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroying
			else
				[ ! -z "$REPORT_SUMMARY" ] && jq -c '{destroyed: [.+{resource:"'"$RESOURCE"'"}]}' $STAGE.destroyed
			fi
			# [ -f $STAGE.omit ] && jq -c '.+{change_action:"omit"}|'"{$RESOURCE:[.]}" $STAGE.omit
		}
	}
	
	local RESOURCE REDUCE_FILTER
	for RESOURCE in "${RESOURCES[@]}"; do
		REDUCE_FILTER="$REDUCE_FILTER $RESOURCE: (if \$item.$RESOURCE then ((.$RESOURCE//{}) + \$item.$RESOURCE) else .$RESOURCE end),"
	done
	[ ! -z "$REPORT_SUMMARY" ] && {
		REDUCE_FILTER="$REDUCE_FILTER"'
			creating: (if $item.creating then ((.creating//[]) + $item.creating) else .creating end),
			updating: (if $item.updating then ((.updating//[]) + $item.updating) else .updating end),
			destroying: (if $item.destroying then ((.destroying//[]) + $item.destroying) else .destroying end),
			created: (if $item.created then ((.created//[]) + $item.created) else .created end),
			updated: (if $item.updated then ((.updated//[]) + $item.updated) else .updated end),
			destroyed: (if $item.destroyed then ((.destroyed//[]) + $item.destroyed) else .destroyed end)' \
		REPORT_FILTER='| with_entries(select(.value))) | . + { 
			changing: (.creating or .updating or .destroying), 
			changed: (.created or .updated or .destroyed)
			}'"$REPORT_FILTER"
	}
	{
		for RESOURCE in "${RESOURCES[@]}"; do
			do_report "$RESOURCE"
		done
		return 0	
	} | jq -sc 'reduce .[] as $item ( {}; {'"$REDUCE_FILTER"'}'"$REPORT_FILTER"
}

apply_actions(){
	local ACTION="$1" INPUT="$2" RESULT="$3" FORK=0 && [ -f $INPUT ] || return 0
	touch $RESULT && (  
		for FORK in $(seq 1 ${NPC_ACTION_FORKS:-1}); do
			[ ! -z "$FORK" ] && rm -f $RESULT.$FORK || continue
			while [ ! -f $RESULT.error ]; do
				flock 91 && read -r ACTION_ITEM <&90 && flock -u 91 || break
				$ACTION "$ACTION_ITEM" "$RESULT.$FORK" "$SECONDS $RESULT" && {
					[ -f "$RESULT.$FORK" ] || echo "$ACTION_ITEM" >"$RESULT.$FORK"
					flock 91 && jq -ce '.' $RESULT.$FORK >>$RESULT && flock -u 91 && continue
				}
				>>$RESULT.error
				rm -f "$RESULT.$FORK"; break
			done 91<$RESULT &
		done 90<$INPUT; wait )
	[ -f $RESULT ] && [ ! -f $RESULT.error ] && rm -f $RESULT.* && return 0
	rm -f $RESULT; return 1
}

time_to_seconds(){
	local SEC="$1"; 
	[[ "$SEC" = *s ]] && SEC="${SEC%s}"
	[[ "$SEC" = *m ]] && SEC="${SEC%m}" && ((SEC *= 60))
	echo "$SEC"
}

action_check_continue(){
	local START RESULT TIMEOUT="$(time_to_seconds "${2:-$NPC_ACTION_TIMEOUT}")"
	read -r START RESULT _<<<"$1"|| return 1
	(( SECONDS - START < TIMEOUT )) || {
		echo "[ERROR] timeout" >&2
		return 1
	}
	[ ! -f $RESULT ] && {
		echo "[ERROR] cancel" >&2
		return 1
	}
	return 0
}

action_sleep(){
	local WAIT_SECONDS="$(time_to_seconds "$1")" && shift;
	while action_check_continue "$@"; do
		(( WAIT_SECONDS-- > 0 )) || return 0; sleep 1s
	done; return 1
}

checked_api(){
	local FILTER ARGS=(); while ! [[ "$1" =~ ^(GET|POST|PUT|DELETE|HEAD)$ ]]; do
		[ ! -z "$FILTER" ] && ARGS=("${ARGS[@]}" "$FILTER")
		FILTER="$1" && shift
	done; ARGS=("${ARGS[@]}" "$@")

	local DO_API=(npc ${NPC_API:-api})
	[ ! -z "$NPC_API_LOCK" ] && DO_API=('flock' "$NPC_API_LOCK" "${DO_API[@]}")
	local RESPONSE="$("${DO_API[@]}" --error "${ARGS[@]}" && \
		[ ! -z "$NPC_API_SUCCEED_NO_RESPONSE" ] && echo '{"ok":"no response"}' )" && [ ! -z "$RESPONSE" ] || {
		[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] No response." >&2
		return 1
	}
	[ "${NPC_API:-api}" == "api" ] && {
		jq_check .code <<<"$RESPONSE" && [ "$(jq -r .code <<<"$RESPONSE")" != "200" ] && {
			[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
			return 1
		}
	}
	if [ ! -z "$FILTER" ]; then
		jq -cre "($FILTER)//empty" <<<"$RESPONSE" && return 0
	else
		jq_check '.' <<<"$RESPONSE" && return 0
	fi
	[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
	return 1
}

checked_api2(){
	NPC_API=api2 checked_api "$@"
}
