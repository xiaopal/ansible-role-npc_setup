#! /bin/bash

plan_resources(){
	local STAGE="$1" INPUT_EXPECTED="$2" INPUT_ACTUAL="$3" STAGE_MAPPER="$4"
	local LINE NAME
	while read -r LINE; do
		for NAME in $(eval "echo $(jq -r '.name'<<<"$LINE")"); do
			[ ! -z "$NAME" ] && NAME="$NAME" jq -c '. + {name:env.NAME}'<<<"$LINE"
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

action_check_continue(){
	local START RESULT TIMEOUT="${2:-$NPC_ACTION_TIMEOUT}"
	read -r START RESULT _<<<"$1"|| return 1
	[[ "$TIMEOUT" = *s ]] && TIMEOUT="${TIMEOUT%s}"
	[[ "$TIMEOUT" = *m ]] && TIMEOUT="${TIMEOUT%m}" && ((TIMEOUT *= 60))
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
