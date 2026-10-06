#!/usr/bin/env bash
# Synchronize OCI Generative AI Hosted Deployments after an image build.

set -euo pipefail

APP_SUFFIX=""
IMAGE=""
CONTAINER_URI=""
IMAGE_TAG=""
ENVIRONMENT_FILE=""
ENVIRONMENT_VARIABLES=()
TEMP_DIR=""

usage() {
    echo "Usage: $0 --app <app-name> --image <fully-qualified-image:tag> [--environment-file <path>]" >&2
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

require_environment() {
    local name=$1
    [ -n "${!name:-}" ] || error "$name must be set before synchronizing a hosted application"
}

oci_genai() {
    oci --region "$TF_VAR_region" generative-ai "$@"
}

cleanup() {
    [ -n "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --app)
                [ "$#" -ge 2 ] || error "--app requires a value"
                case "$2" in
                    mcp_server) APP_SUFFIX=mcp ;;
                    *)
                        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || error "Invalid hosted application name: $2"
                        APP_SUFFIX=$2
                        ;;
                esac
                shift 2
                ;;
            --image)
                [ "$#" -ge 2 ] || error "--image requires a value"
                IMAGE=$2
                shift 2
                ;;
            --environment-file)
                [ "$#" -ge 2 ] || error "--environment-file requires a value"
                ENVIRONMENT_FILE=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done

    [ -n "$APP_SUFFIX" ] || error "--app is required"
    [ -n "$IMAGE" ] || error "--image is required"
    if [ -n "$ENVIRONMENT_FILE" ] && [ -e "$ENVIRONMENT_FILE" ] && [ ! -f "$ENVIRONMENT_FILE" ]; then
        error "Environment file is not a regular file: $ENVIRONMENT_FILE"
    fi
}

split_image() {
    CONTAINER_URI=${IMAGE%:*}
    IMAGE_TAG=${IMAGE##*:}
    [ "$CONTAINER_URI" != "$IMAGE" ] && [ -n "$CONTAINER_URI" ] && [ -n "$IMAGE_TAG" ] \
        || error "Expected a fully-qualified, tagged container image; got $IMAGE"
}

single_active_id() {
    local json=$1
    local description=$2
    local ids
    ids=$(jq -er '
        [.data.items[]?
         | select((.["lifecycle-state"] // .lifecycleState) != "DELETED"
                  and (.["lifecycle-state"] // .lifecycleState) != "DELETING")
         | .id]
        | if length == 1 then .[0]
          elif length == 0 then empty
          else error("multiple active resources")
          end
    ' <<<"$json") || error "Expected exactly one $description"
    [ -n "$ids" ] || error "Expected exactly one $description; found none"
    printf '%s\n' "$ids"
}

deployment_id_or_empty() {
    local json=$1
    jq -er '
        [.data.items[]?
         | select((.["lifecycle-state"] // .lifecycleState) != "DELETED"
                  and (.["lifecycle-state"] // .lifecycleState) != "DELETING")
         | .id]
        | if length == 0 then ""
          elif length == 1 then .[0]
          else error("multiple active resources")
          end
    ' <<<"$json" || error "Expected at most one active Hosted Deployment"
}

parse_environment_file() {
    local line line_number=0 variable_name
    # Bash 3.2 (the macOS system Bash) has no associative arrays. Environment
    # variable names are shell-safe identifiers, so a space-delimited set is a
    # portable way to retain the duplicate-name validation.
    local declared_names=" "

    ENVIRONMENT_VARIABLES=()
    # An app without app.env has no runtime variables to inject.
    [ -n "$ENVIRONMENT_FILE" ] && [ -f "$ENVIRONMENT_FILE" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        ((line_number += 1))
        line=${line%%#*}
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]]; then
            variable_name=${BASH_REMATCH[1]}
            case "$declared_names" in
                *" $variable_name "*)
                    error "$ENVIRONMENT_FILE:$line_number: duplicate environment variable $variable_name"
                    ;;
            esac
            declared_names+="$variable_name "
            ENVIRONMENT_VARIABLES+=("$variable_name")
            continue
        fi

        error "$ENVIRONMENT_FILE:$line_number: expected one shell-safe environment variable name"
    done < "$ENVIRONMENT_FILE"
}

validate_environment_variables() {
    local variable_name
    for variable_name in "${ENVIRONMENT_VARIABLES[@]}"; do
        require_environment "$variable_name"
    done
}

manifest_environment_json() {
    local variable_name
    local jq_arguments=(-n)

    for variable_name in "${ENVIRONMENT_VARIABLES[@]}"; do
        jq_arguments+=(--arg "$variable_name" "${!variable_name}")
    done

    jq "${jq_arguments[@]}" '
        $ARGS.named
        | to_entries
        | map({name: .key, type: "PLAINTEXT", value: .value})
    '
}

merge_runtime_environment() {
    local application_json=$1
    local manifest_environment=$2
    jq --argjson manifest_environment "$manifest_environment" '
        (.data["environment-variables"] // .data.environmentVariables // []) as $variables
        | ($manifest_environment | map(.name)) as $manifest_names
        | [ $variables[]
            | select(.name as $name | $manifest_names | index($name) | not)
          ] + $manifest_environment
    ' <<<"$application_json"
}

main() {
    parse_arguments "$@"
    require_environment TF_VAR_compartment_ocid
    require_environment TF_VAR_prefix
    require_environment TF_VAR_region
    parse_environment_file
    validate_environment_variables
    command -v oci >/dev/null 2>&1 || error "OCI CLI not found"
    command -v jq >/dev/null 2>&1 || error "jq not found"
    split_image

    TEMP_DIR=$(mktemp -d /tmp/hosted-app-cli.XXXXXX)
    trap cleanup EXIT

    local display_name="${TF_VAR_prefix}-${APP_SUFFIX}-hosted-app"
    local applications application_id application_details manifest_environment
    applications=$(oci_genai hosted-application-collection list-hosted-applications \
        --compartment-id "$TF_VAR_compartment_ocid" \
        --display-name "$display_name" \
        --all)
    application_id=$(single_active_id "$applications" "Hosted Application named $display_name")
    application_details=$(oci_genai hosted-application get \
        --hosted-application-id "$application_id")

    if [ "${#ENVIRONMENT_VARIABLES[@]}" -gt 0 ]; then
        manifest_environment=$(manifest_environment_json)
        merge_runtime_environment "$application_details" "$manifest_environment" > "$TEMP_DIR/environment-variables.json"
        oci_genai hosted-application update \
            --hosted-application-id "$application_id" \
            --environment-variables "file://$TEMP_DIR/environment-variables.json" \
            --force \
            --wait-for-state SUCCEEDED \
            --max-wait-seconds 1200 \
            --wait-interval-seconds 10 >/dev/null
        application_details=$(oci_genai hosted-application get \
            --hosted-application-id "$application_id")
    fi

    jq -e '.data["freeform-tags"] // .data.freeformTags // {}' <<<"$application_details" > "$TEMP_DIR/freeform-tags.json"
    jq -n --arg uri "$CONTAINER_URI" --arg tag "$IMAGE_TAG" \
        '{artifactType: "SIMPLE_DOCKER_ARTIFACT", containerUri: $uri, tag: $tag, isVulnerabilityScanRequired: false}' \
        > "$TEMP_DIR/active-artifact.json"

    local deployments deployment_id
    deployments=$(oci_genai hosted-deployment-collection list-hosted-deployments \
        --compartment-id "$TF_VAR_compartment_ocid" \
        --application-id "$application_id" \
        --all)
    deployment_id=$(deployment_id_or_empty "$deployments")

    if [ -z "$deployment_id" ]; then
        oci_genai hosted-deployment create \
            --compartment-id "$TF_VAR_compartment_ocid" \
            --hosted-application-id "$application_id" \
            --active-artifact "file://$TEMP_DIR/active-artifact.json" \
            --freeform-tags "file://$TEMP_DIR/freeform-tags.json" \
            --wait-for-state SUCCEEDED \
            --max-wait-seconds 1200 \
            --wait-interval-seconds 10 >/dev/null
    else
        # An artifact is immutable once attached to a deployment. Add the newly
        # pushed tag first, then make that returned artifact active.
        oci_genai hosted-deployment add \
            --hosted-deployment-id "$deployment_id" \
            --artifact "file://$TEMP_DIR/active-artifact.json" \
            --wait-for-state SUCCEEDED \
            --max-wait-seconds 1200 \
            --wait-interval-seconds 10 >/dev/null
        oci_genai hosted-deployment update \
            --hosted-deployment-id "$deployment_id" \
            --active-artifact "file://$TEMP_DIR/active-artifact.json" \
            --force \
            --wait-for-state SUCCEEDED \
            --max-wait-seconds 1200 \
            --wait-interval-seconds 10 >/dev/null
    fi

    echo "Hosted Deployment synchronized for $display_name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
