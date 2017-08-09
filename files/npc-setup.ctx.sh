#! /bin/bash

plan_resources(){
	local STAGE="$1" INPUT_EXPECTED="$2" INPUT_ACTUAL="$3" STAGE_MAPPER="$4"
	local LINE NAME
	while read -r LINE; do
		local NAMES=($(eval "echo $(jq -r '.name|sub("^\\*\\:"; "")'<<<"$LINE")")) NAME_INDEX
		for NAME in "${NAMES[@]}"; do
			[ ! -z "$NAME" ] || continue
			while read -r STM_LINE; do 
				jq_check 'length>1 and (.[1]|strings|startswith("*:"))'<<<"$STM_LINE" || {
					echo "$STM_LINE" && continue
				}
				local STM_VALS=($(eval "echo $(jq -r '.[1]|sub("^\\*\\:"; "")'<<<"$STM_LINE")")) STM_VAL_INDEX
				for STM_VAL in "${STM_VALS[@]}"; do
					(( STM_VAL_INDEX++ == NAME_INDEX % ${#STM_VALS[@]} )) \
						&& STM_VAL="$STM_VAL" jq -c '[.[0],env.STM_VAL]' <<<"$STM_LINE"
				done 
			done < <(NAME="$NAME" jq --argjson index "$((NAME_INDEX))" -c '. + {name:env.NAME, name_index:$index}|tostream'<<<"$LINE") \
				| jq -s 'fromstream(.[])'; ((NAME_INDEX++))
		done
	done < <(jq -c 'arrays[]' $INPUT_EXPECTED || >>$STAGE.error) \
		| jq -sc 'map({ key:.name, value:. }) | from_entries' >$STAGE.expected \
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
	jq -ce '.[]|select(.create)' $STAGE > $STAGE.creating || rm -f $STAGE.creating
	jq -ce '.[]|select(.update)' $STAGE > $STAGE.updating || rm -f $STAGE.updating

	if [ ! -z "$ACTION_OMIT_ABSENT" ]; then
		jq -ce '.[]|select(.destroy)' $STAGE > $STAGE.destroying || rm -f $STAGE.destroying
		jq -ce '.[]|select(.absent)' $STAGE > $STAGE.omit || rm -f $STAGE.omit
	else
		jq -ce '.[]|select(.destroy or .absent)' $STAGE > $STAGE.destroying || rm -f $STAGE.destroying
	fi
}

apply_actions(){
	local ACTION="$1" INPUT="$2" RESULT="$3" FORK=0 && [ -f $INPUT ] || return 0
	do_wait(){
		wait && [ -f $RESULT ] || return 1
		for I in $(seq 0 "$((FORK-1))"); do
			[ -f $RESULT.$I ] && jq -ce '.' $RESULT.$I >> $RESULT || {
				rm -f $RESULT
				return 1
			}
		done
	}
	touch $RESULT && while read -r ACTION_ITEM; do
		rm -f $RESULT.$FORK && touch $RESULT
		{ 
			$ACTION "$ACTION_ITEM" "$RESULT.$FORK" "$SECONDS $RESULT" && {
				[ -f "$RESULT.$FORK" ] || echo "$ACTION_ITEM" >"$RESULT.$FORK"
			} || {
				rm -f "$RESULT.$FORK"
				rm -f $RESULT
			}
		}&
		((++FORK >= ${NPC_ACTION_FORKS:-1})) && {
			do_wait || return 1
			FORK=0
		}
	done <$INPUT
	do_wait || return 1
	rm -f $RESULT.*
	return 0
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

checked_api(){
	local FILTER ARGS=(); while ! [[ "$1" =~ ^(GET|POST|PUT|DELETE|HEAD)$ ]]; do
		[ ! -z "$FILTER" ] && ARGS=("${ARGS[@]}" "$FILTER")
		FILTER="$1" && shift
	done; ARGS=("${ARGS[@]}" "$@")
	local RESPONSE="$(npc api --error "${ARGS[@]}")" && [ ! -z "$RESPONSE" ] || {
		[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] No response." >&2
		return 1
	}
	jq_check .code <<<"$RESPONSE" && [ "$(jq -r .code <<<"$RESPONSE")" != "200" ] && {
		[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
		return 1
	}
	if [ ! -z "$FILTER" ]; then
		jq -ce "($FILTER)//empty" <<<"$RESPONSE" && return 0
	else
		jq_check '.' <<<"$RESPONSE" && return 0
	fi
	[ ! -z "$OPTION_SILENCE" ] || echo "[ERROR] $RESPONSE" >&2
	return 1
}
