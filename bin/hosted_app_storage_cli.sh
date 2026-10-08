#!/usr/bin/env bash
# Manage PostgreSQL Hosted Application Storage, retaining its OCID for destroy.
set -euo pipefail

error() {
    echo "ERROR: $*" >&2
    exit 1
}

require_environment() {
    [ -n "${!1:-}" ] || error "$1 must be set"
}

oci_storage() {
    oci --region "$STORAGE_REGION" --profile "$STORAGE_PROFILE" \
        generative-ai hosted-application-storage "$@"
}

validate_ocid() {
    [[ "$1" =~ ^ocid1\.[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+$ ]] \
        || error "Invalid storage OCID in $STORAGE_OCID_FILE"
}

read_ocid() {
    [ -f "$STORAGE_OCID_FILE" ] || error "Missing storage OCID file: $STORAGE_OCID_FILE"
    STORAGE_ID=$(cat "$STORAGE_OCID_FILE")
    validate_ocid "$STORAGE_ID"
}

create_storage() {
    require_environment STORAGE_COMPARTMENT_ID
    require_environment STORAGE_DISPLAY_NAME
    require_environment STORAGE_FREEFORM_TAGS
    jq -e 'type == "object" and all(.[]; type == "string")' \
        <<<"$STORAGE_FREEFORM_TAGS" >/dev/null

    if [ -e "$STORAGE_OCID_FILE" ]; then
        # A previous create may have succeeded before its readiness check failed.
        read_ocid
    else
        mkdir -p "$(dirname "$STORAGE_OCID_FILE")"
        local creation_result
        creation_result=$(oci_storage create \
            --compartment-id "$STORAGE_COMPARTMENT_ID" \
            --display-name "$STORAGE_DISPLAY_NAME" \
            --storage-type POSTGRESQL \
            --freeform-tags "$STORAGE_FREEFORM_TAGS" \
            --wait-for-state SUCCEEDED \
            --max-wait-seconds 1200 \
            --wait-interval-seconds 10 \
            --output json)
        # With a waiter, the CLI returns the work request, not the storage.
        STORAGE_ID=$(jq -er '
            if .data.status == "SUCCEEDED" then
                [.data.resources[]?
                 | select(.["action-type"] == "CREATED")
                 | .identifier]
                | if length == 1 then .[0]
                  else error("expected exactly one created storage resource") end
            else error("storage creation work request did not succeed") end
        ' <<<"$creation_result")
        validate_ocid "$STORAGE_ID"
        # Publish the storage OCID only after the creation work request succeeds.
        local temporary_file
        temporary_file=$(mktemp "${STORAGE_OCID_FILE}.XXXXXX")
        printf '%s\n' "$STORAGE_ID" > "$temporary_file"
        mv "$temporary_file" "$STORAGE_OCID_FILE"
    fi

    local deadline=$((SECONDS + 1200)) details state
    while :; do
        details=$(oci_storage get --hosted-application-storage-id "$STORAGE_ID")
        jq -e --arg compartment "$STORAGE_COMPARTMENT_ID" \
            --arg name "$STORAGE_DISPLAY_NAME" --arg id "$STORAGE_ID" '
            .data.id == $id and .data["compartment-id"] == $compartment
            and .data["display-name"] == $name
            and .data["storage-type"] == "POSTGRESQL"
        ' <<<"$details" >/dev/null \
            || error "Recorded storage does not match the requested PostgreSQL database"
        state=$(jq -er '.data["lifecycle-state"]' <<<"$details")
        case "$state" in
            ACTIVE) return 0 ;;
            CREATING|UPDATING) ;;
            *) error "Storage $STORAGE_ID reached unexpected state: $state" ;;
        esac
        [ "$SECONDS" -lt "$deadline" ] || error "Timed out waiting for storage $STORAGE_ID to become ACTIVE"
        sleep 10
    done
}

delete_storage() {
    read_ocid
    oci_storage delete --hosted-application-storage-id "$STORAGE_ID" \
        --force --wait-for-state SUCCEEDED --max-wait-seconds 1200
    rm "$STORAGE_OCID_FILE"
}

main() {
    [ "$#" -eq 1 ] || error "Usage: $0 create|delete"
    require_environment STORAGE_OCID_FILE
    require_environment STORAGE_REGION
    require_environment STORAGE_PROFILE
    command -v oci >/dev/null 2>&1 || error "OCI CLI not found"
    command -v jq >/dev/null 2>&1 || error "jq not found"
    case "$1" in
        create) create_storage ;;
        delete) delete_storage ;;
        *) error "Usage: $0 create|delete" ;;
    esac
}

main "$@"
