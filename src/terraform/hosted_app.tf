# Temporary solution to generate a issue with 403-NotAllowed, Hosted deployment is not supported 
locals {
    local_genai_region = var.region == "eu-amsterdam-1" ? "eu-frankfurt-1" : local.home_region
}

###############################################################################
# UI hosted application
###############################################################################

resource "oci_generative_ai_hosted_application_storage" "litellm_postgres" {
  compartment_id = local.lz_app_cmp_ocid
  display_name   = "${var.prefix}-litellm-postgres"
  storage_type   = "POSTGRESQL"

  freeform_tags = local.freeform_tags
}

resource "oci_generative_ai_hosted_application" "starter_ui_hosted_application" {
  compartment_id = local.lz_app_cmp_ocid
  display_name   = "${var.prefix}-ui-hosted-app"

  inbound_auth_config {
    inbound_auth_config_type = "NO_AUTH_CONFIG"
  }

  networking_config {
    inbound_networking_config {
      endpoint_mode = "PUBLIC"
    }

    outbound_networking_config {
      network_mode     = "CUSTOM"
      custom_subnet_id = data.oci_core_subnet.starter_app_subnet.id
    }
  }

  scaling_config {
    scaling_type         = "CPU"
    min_replica          = 1
    max_replica          = 1
    target_cpu_threshold = 50
  }

  storage_configs {
    storage_id               = oci_generative_ai_hosted_application_storage.litellm_postgres.id
    environment_variable_key = "DATABASE_URL"
  }

  freeform_tags = local.freeform_tags
}


###############################################################################
# MCP hosted application/deployment
###############################################################################


###############################################################################
# Hosted application invoke URLs
#
# Equivalent to the old Container Instance private IP destinations.
###############################################################################

locals {
  hosted_application_base_url = "https://inference.generativeai.${var.region}.oci.oraclecloud.com/20251112/hostedApplications"
  hosted_ui_invoke_url   = "${local.hosted_application_base_url}/${oci_generative_ai_hosted_application.starter_ui_hosted_application.id}/actions/invoke"
}


###############################################################################
# API Gateway
###############################################################################

resource "oci_apigateway_deployment" "starter_apigw_deployment" {

  compartment_id = local.lz_app_cmp_ocid
  display_name   = "${var.prefix}-apigw-deployment"
  gateway_id     = local.apigw_ocid
  path_prefix    = "/${var.prefix}"

  specification {
    logging_policies {
      access_log {
        is_enabled = true
      }

      execution_log {
        is_enabled = true
      }
    }

    #########################################################################
    # UI
    #
    # Old:
    # http://<container-private-ip>/*
    #
    # New:
    # UI hosted application /*
    #########################################################################

    routes {
      path    = "/{pathname*}"
      methods = ["ANY"]

      backend {
        type = "HTTP_BACKEND"
        url  = "${local.hosted_ui_invoke_url}/$${request.path[pathname]}"
      }

      # The Hosted Application gateway consumes Authorization before LiteLLM
      # sees it. Preserve OpenAI-compatible Bearer tokens under LiteLLM's
      # custom header on the backend request.
      request_policies {
        header_transformations {
          rename_headers {
            items {
              from = "Authorization"
              to   = "x-litellm-api-key"
            }
          }
        }
      }
    }
  }

  freeform_tags = local.api_tags
}


###############################################################################
# Hosted Application service logs
#
# The log group is Terraform-managed. Each service log is bound to its Hosted
# Application, so Terraform recreates it if that application is replaced.
###############################################################################

resource "oci_logging_log" "starter_ui_hosted_app_log" {
  display_name = "${var.prefix}-ui-hosted-app_genai-hosted-deployment-log"
  log_group_id = oci_logging_log_group.starter_log_group.id
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = local.lz_app_cmp_ocid

    source {
      category    = "genai-hosted-deployment-log"
      resource    = oci_generative_ai_hosted_application.starter_ui_hosted_application.id
      service     = "genai-hosted-deployment-prod"
      source_type = "OCISERVICE"
    }
  }
}
