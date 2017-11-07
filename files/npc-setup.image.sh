#! /bin/bash

setup_resources "instance_images"

init_instance_images(){
	local INPUT="$1" STAGE="$2"
	jq_check '.npc_instance_images|arrays' $INPUT && {
		plan_resources "$STAGE" \
			<(jq -c '.npc_instance_images//[]' $INPUT || >>$STAGE.error) \
			<(npc api 'json.images|map({
				id: .imageId,
				name: .imageName
			})' GET "/api/v1/vm/privateimages?pageSize=9999&pageNum=1&keyword=" || >>$STAGE.error) \
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
			load_instances '{id: .uuid,name: .name}' >$STAGE || rm -f $STAGE
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
	local FROM_INSTANCE="$(lookup_from_instance "$(jq -r '.from_instance//empty'<<<"$IMAGE")")" \
		&& [ ! -z "$FROM_INSTANCE" ] || return 1
	local SAVE_IMAGE="$(FROM_INSTANCE="$FROM_INSTANCE" jq -c '{
		name: .name,
		uuid: env.FROM_INSTANCE,
		description: (.description//"created by npc-setup")
	}'<<<"$IMAGE")"
	instances_wait_instance "$FROM_INSTANCE" "$CTX" \
		&& local IMAGE_ID="$(checked_api '.imageId' POST "/api/v1/vm/privateimage" "$SAVE_IMAGE")" \
		&& [ ! -z "$IMAGE_ID" ] && instances_wait_instance "$FROM_INSTANCE" "$CTX" && {
			echo "[INFO] instance_image '$IMAGE_ID' saved." >&2
			return 0
		}
	return 1
}

instance_images_destroy(){
	local IMAGE="$1" RESULT="$2" CTX="$3" && [ ! -z "$IMAGE" ] || return 1
	local IMAGE_ID="$(jq -r .id<<<"$IMAGE")" && [ ! -z "$IMAGE_ID" ] || return 1
	checked_api DELETE "/api/v1/vm/privateimage/$IMAGE_ID" && {
		echo "[INFO] instance_image '$IMAGE_ID' destroyed." >&2
		return 0
	}
	return 1
}
