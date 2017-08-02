#! /bin/bash

ssh_key_fingerprint(){
	local KEY_FILE="$1" && [ -f "$KEY_FILE" ] \
		&& read _ FINGERPRINT _<<<"$(ssh-keygen -lE md5 -f "$KEY_FILE")" \
		&& echo "${FINGERPRINT#MD5:}"
}

check_ssh_keys(){
	local STAGE="$NPC_STAGE/ssh_keys" FORCE_CREATE CHECK_FILE
	while ARG="$1" && shift; do
		case "$ARG" in
			--check-file)
				CHECK_FILE=Y
				;;
			--create)
				FORCE_CREATE=Y
				CHECK_FILE=Y
				;;
		esac
	done
	while read -r SSH_KEY; do
		( exec 100>$STAGE.lock && flock 100
			[ -f $STAGE ] || {
				npc api 'json|arrays|map({key:.name, value:.})|from_entries' \
					GET "/api/v1/secret-keys" >$STAGE || { rm -f $STAGE; exit 1; }				
			}
			local STAGE_SSH_KEY="$(jq -c --arg ssh_key "$SSH_KEY" '.[$ssh_key]//empty' $STAGE)" \
				SSH_KEY_FILE="$(cd ~; pwd)/.npc/ssh_key.$SSH_KEY"
			[ ! -z "$STAGE_SSH_KEY" ] && {
				[ ! -z "$CHECK_FILE" ] || exit 0
				[ -f "$SSH_KEY_FILE" ] \
					&& [ "$(ssh_key_fingerprint "$SSH_KEY_FILE")" = "$(jq -r '.fingerprint'<<<"$STAGE_SSH_KEY")" ] \
					&& exit 0
			}
			[ -f "$SSH_KEY_FILE" ] && {
				[ ! -z "$STAGE_SSH_KEY" ] && {
					echo "[ERROR] ssh_key '$SSH_KEY' fingerprint mismatch" >&2
					exit 1
				}
				echo "[ERROR] '$SSH_KEY_FILE' already exists" >&2
				exit 1
			}
			local SSH_KEY_ID
			[ ! -z "$STAGE_SSH_KEY" ] && SSH_KEY_ID="$(jq -r '.id'<<<"$STAGE_SSH_KEY")" || {
				echo "[ERROR] ssh_key '$SSH_KEY' not found" >&2
				[ ! -z "$FORCE_CREATE" ] && {
					rm -f $STAGE && mkdir -p "$(dirname "$SSH_KEY_FILE")"
					STAGE_SSH_KEY="$(npc api 'json|select(.id and .fingerprint)' \
						POST /api/v1/secret-keys "$(jq -Rc "{key_name:.}"<<<"$SSH_KEY")")"
					[ ! -z "$STAGE_SSH_KEY" ] && SSH_KEY_ID="$(jq -r '.id'<<<"$STAGE_SSH_KEY")" || {
						echo "[ERROR] Failed to create ssh_key '$SSH_KEY'" >&2
					}
				}
			}
			[ ! -z "$SSH_KEY_ID" ] && [ ! -z "$FORCE_CREATE" ] && {
				npc api GET "/api/v1/secret-keys/$SSH_KEY_ID" >$SSH_KEY_FILE \
					&& chmod 600 $SSH_KEY_FILE \
					&& [ "$(ssh_key_fingerprint "$SSH_KEY_FILE")" = "$(jq -r '.fingerprint'<<<"$STAGE_SSH_KEY")" ] \
					&& exit 0
				rm -f $SSH_KEY_FILE
				echo "[ERROR] Failed to download ssh_key '$SSH_KEY'" >&2
			} 
			echo "[ERROR] '$SSH_KEY_FILE' not exists" >&2
			exit 1			
		) || return 1
	done
	return 0
}
