# Temporary solution to generate a issue with 403-NotAllowed, Hosted deployment is not supported 
locals {
  local_genai_region = var.region == "eu-amsterdam-1" ? "eu-frankfurt-1" : local.home_region
}

###############################################################################
# UI hosted application
###############################################################################

resource "null_resource" "litellm_postgres" {
  triggers = {
    helper_path    = abspath("${local.project_dir}/bin/hosted_app_storage_cli.sh")
    ocid_file      = abspath("${local.project_dir}/target/hosted_application_storage.ocid")
    region         = var.region
    profile        = var.config_file_profile
    compartment_id = local.lz_app_cmp_ocid
    display_name   = "${var.prefix}-litellm-postgres"
    freeform_tags  = jsonencode(local.freeform_tags)
  }

  provisioner "local-exec" {
    command = "bash \"$STORAGE_HELPER\" create"
    environment = {
      STORAGE_HELPER         = self.triggers.helper_path
      STORAGE_OCID_FILE      = self.triggers.ocid_file
      STORAGE_REGION         = self.triggers.region
      STORAGE_PROFILE        = self.triggers.profile
      STORAGE_COMPARTMENT_ID = self.triggers.compartment_id
      STORAGE_DISPLAY_NAME   = self.triggers.display_name
      STORAGE_FREEFORM_TAGS  = self.triggers.freeform_tags
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"$STORAGE_HELPER\" delete"
    environment = {
      STORAGE_HELPER    = self.triggers.helper_path
      STORAGE_OCID_FILE = self.triggers.ocid_file
      STORAGE_REGION    = self.triggers.region
      STORAGE_PROFILE   = self.triggers.profile
    }
  }
}

# Retain this file alongside Terraform state: the destroy provisioner needs it.
data "local_file" "litellm_postgres_ocid" {
  filename   = null_resource.litellm_postgres.triggers.ocid_file
  depends_on = [null_resource.litellm_postgres]
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
    storage_id               = trimspace(data.local_file.litellm_postgres_ocid.content)
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
  hosted_ui_invoke_url        = "${local.hosted_application_base_url}/${oci_generative_ai_hosted_application.starter_ui_hosted_application.id}/actions/invoke"
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
