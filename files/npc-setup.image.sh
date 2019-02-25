#! /bin/bash

setup_resources "instance_images"

init_instance_images(){
	local INPUT="$1" STAGE="$2"
	jq_check '.npc_instance_images|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '.npc_instance_images//[]' $INPUT || >>$STAGE.error) \
			<(checked_api2 '.Images|map({
					id: .ImageId,
					name: .ImageName
				})' POST '/nvm?Action=DescribeImages&Version=2017-12-14&Limit=9999&Offset=0' '{"Filter":{"ImageType": ["Private"]}}' || >>$STAGE.error) \
			'. + {update: false}' || return 1
	}
	return 0
}

lookup_from_instance(){
	local INSTANCE_NAME="$1" STAGE="$NPC_STAGE/from_instances" && [ ! -z "$INSTANCE_NAME" ] || {
		echo "[ERROR] from_instance required" >&2
		return 1
	}
	( exec 100>$STAGE.lock && flock 100
		[ ! -f $STAGE ] && {
			load_instances '{id: .InstanceId,name: .InstanceName}' >$STAGE || rm -f $STAGE
		}
	)
	[ -f $STAGE ] && INSTANCE_NAME="$INSTANCE_NAME" \
		jq -re '.[]|select(.name==env.INSTANCE_NAME or .id==env.INSTANCE_NAME)|.id' $STAGE	\
		&& return 0
	echo "[ERROR] from_instance - '$INSTANCE_NAME' not found" >&2
	return 1
}

instance_images_create(){
	local IMAGE="$1" RESULT="$2" CTX="$3" && [ ! -z "$IMAGE" ] || return 1
	local FROM_INSTANCE="$(INSTANCES_LOOKUP_KEY='from_instances' instances_lookup "$(jq -r '.from_instance//empty'<<<"$IMAGE")")" \
		&& [ ! -z "$FROM_INSTANCE" ] || return 1
	local IMAGE_ID SAVE_IMAGE_PARAMS="$(FROM_INSTANCE="$FROM_INSTANCE" jq -r '{
			ImageName: .name,
			InstanceId: env.FROM_INSTANCE,
			Description: (.description//"created by npc-setup"|@base64)
		}|to_entries|map(@uri"\(.key)=\(.value)")|join("&")'<<<"$IMAGE")"
	instances_wait_instance "$FROM_INSTANCE" "$CTX" \
		&& IMAGE_ID="$(checked_api2 '.ImageId' GET "/nvm?Action=CreateImage&Version=2017-12-14&$SAVE_IMAGE_PARAMS")" \
		&& [ ! -z "$IMAGE_ID" ] && instances_wait_instance "$FROM_INSTANCE" "$CTX" && {
			echo "[INFO] instance_image '$IMAGE_ID' saved." >&2
			return 0
		}
	return 1
}

instance_images_destroy(){
	local IMAGE="$1" RESULT="$2" CTX="$3" && [ ! -z "$IMAGE" ] || return 1
	local IMAGE_ID="$(jq -r .id<<<"$IMAGE")" && [ ! -z "$IMAGE_ID" ] || return 1
	checked_api2 GET "/nvm?Action=DeleteImage&Version=2017-12-14&ImageId=$IMAGE_ID" && {
		echo "[INFO] instance_image '$IMAGE_ID' destroyed." >&2
		return 0
	}
	return 1
}
