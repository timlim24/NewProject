# Keep project_id in sync with gcp/bootstrap/terraform.tfvars.
project_id = "spry-514721"
region     = "us-central1"
name       = "new-project"

# From infra/ (terraform output UserPoolId / UserPoolClientId): public IDs, not secrets.
cognito_user_pool_id = "us-east-1_rKwoqaQL8"
cognito_client_id    = "4qu2pkacbb1r6c1vgeu6q6kfc8"
