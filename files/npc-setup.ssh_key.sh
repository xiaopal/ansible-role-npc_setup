#! /bin/bash

ssh_key_fingerprint(){
    local KEY_FILE="$1" && [ -f "$KEY_FILE" ] \
        && read _ FINGERPRINT _<<<"$(ssh-keygen -lE md5 -f "$KEY_FILE")" \
        && echo "${FINGERPRINT#MD5:}"
}

check_ssh_keys(){
    local STAGE="$NPC_STAGE/ssh_keys" FORCE_CREATE CHECK_FILE OUTPUT_FILTER
    while ARG="$1" && shift; do
        case "$ARG" in
            --check-file)
                CHECK_FILE=Y
                ;;
            --create)
                FORCE_CREATE=Y
                CHECK_FILE=Y
                ;;
            --output)
                OUTPUT_FILTER="$1" && shift
                ;;
        esac
    done
    while read -r SSH_KEY; do
        ( exec 100>$STAGE.lock && flock 100
            [ -f $STAGE ] || {
                checked_api2 '.Results//empty|map({key:.KeyName, value:{
                    id: .Id,
                    name: .KeyName,
                    fingerprint: .Fingerprint
                }})|from_entries' \
                GET '/keypair?Action=ListKeyPair&Version=2018-02-08&Limit=9999&Offset=0' >$STAGE || {
                    rm -f $STAGE; exit 1
                }
            }
            local STAGE_SSH_KEY="$(jq -c --arg ssh_key "$SSH_KEY" '.[$ssh_key]//empty' $STAGE)" \
                SSH_KEY_FILE="$(cd ~; pwd)/.npc/ssh_key.$SSH_KEY"
            [ ! -z "$STAGE_SSH_KEY" ] && {
                [ ! -z "$OUTPUT_FILTER" ] && jq -cr "$OUTPUT_FILTER"<<<"$STAGE_SSH_KEY"
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
                    rm -f "$STAGE"
                    STAGE_SSH_KEY="$(checked_api2 '{
							id: .Id,
							name: .KeyName,
							fingerprint: .Fingerprint,
							private_key: .PrivateKey
						}' GET "/keypair?Action=CreateKeyPair&Version=2018-02-08&KeyName=$SSH_KEY")" && \
					[ ! -z "$STAGE_SSH_KEY" ] && { 
                        [ ! -z "$OUTPUT_FILTER" ] && jq -cr "$OUTPUT_FILTER"<<<"$STAGE_SSH_KEY"
                        SSH_KEY_ID="$(jq -r '.id'<<<"$STAGE_SSH_KEY")" 
                    } || {
                        echo "[ERROR] Failed to create ssh_key '$SSH_KEY'" >&2
                    }
                }
            }
            [ ! -z "$SSH_KEY_ID" ] && [ ! -z "$FORCE_CREATE" ] && {
				mkdir -p "$(dirname "$SSH_KEY_FILE")"
				checked_api2 '.PrivateKey//empty' \
					GET "/keypair?Action=GetKeyPairPrivateKey&Version=2018-02-08&Id=$SSH_KEY_ID" >$SSH_KEY_FILE \
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
