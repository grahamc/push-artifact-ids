set -eu

ARTIFACTS_DIRECTORY="$1"
TYPE="$2"
TYPE_ID="$3"
GIT_ISH="$4"

if [ "$TYPE" == "tag" ]; then
  DEST="${TYPE_ID}"
else
  DEST="${TYPE}_${TYPE_ID}"
fi

is_tag() {
  if [[ "$GITHUB_REF_TYPE" == "tag" ]]; then
    return 0
  else
    return 1
  fi
}

# If the revision directory has already been created in S3 somehow, we don't want to reupload
if aws s3 ls "$AWS_BUCKET"/"$GIT_ISH"/; then
  # Only exit if it's not a tag (since we're tagging a commit previously pushed to main)
  if ! is_tag; then
    echo "Revision $GIT_ISH was already uploaded; exiting"
    exit 1
  fi
fi

mkdir "$DEST"
mkdir "$GIT_ISH"

for artifact in $(find "$ARTIFACTS_DIRECTORY/" -type f); do
  chmod +x "$artifact"
  cp "$artifact" "$DEST"/
  cp "$artifact" "$GIT_ISH"/
done

# If any artifact already exists in S3 and the hash is the same, we don't want to reupload
check_reupload() {
  dest="$1"

  for file in $(find "$dest" -type f); do
    artifact_path="$dest"/"$(basename "$artifact")"
    md5="$(md5sum "$artifact" | cut -d' ' -f1)"
    obj="$(aws s3api head-object --bucket "$AWS_BUCKET" --key "$artifact_path" || echo '{}')"
    obj_md5="$(jq -r .ETag <<<"$obj" | jq -r)" # head-object call returns ETag quoted, so `jq -r` again to unquote it

    if [[ "$md5" == "$obj_md5" ]]; then
      echo "Artifact $artifact was already uploaded; exiting"
      # If we already uploaded to a tag, that's probably bad
      is_tag && exit 1 || exit 0
    fi
  done
}

check_reupload "$DEST"
if ! is_tag; then
  check_reupload "$GIT_ISH"
fi

aws s3 sync "$DEST"/ s3://"$AWS_BUCKET"/"$DEST"/ --acl public-read
if ! is_tag; then
  aws s3 sync "$GIT_ISH"/ s3://"$AWS_BUCKET"/"$GIT_ISH"/ --acl public-read
fi


cat <<-EOF >> $GITHUB_STEP_SUMMARY
This commit's ${IDS_PROJECT} artifacts can be fetched via:

EOF

for artifact in $(find "$ARTIFACTS_DIRECTORY/" -type f); do
    cat <<-EOF >> $GITHUB_STEP_SUMMARY
\`\`\`
curl --output fh --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/${IDS_PROJECT}/rev/$GIT_ISH/${artifact}
\`\`\`
EOF
done


cat <<-EOF >> $GITHUB_STEP_SUMMARY
Or generally from this ${TYPE}:

EOF

for artifact in $(find "$ARTIFACTS_DIRECTORY/" -type f); do
    cat <<-EOF >> $GITHUB_STEP_SUMMARY
\`\`\`
curl --output fh --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/${IDS_PROJECT}/${TYPE}/${TYPE_ID}/${artifact}
\`\`\`

EOF
done
