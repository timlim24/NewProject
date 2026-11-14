# Pick your own project ID; it is global and permanent. Keep it in sync with gcp/terraform.tfvars.
project_id = "spry-514721"
region     = "us-central1"
name       = "new-project"

# HCP Terraform organization ooad-timlim and workspace new-project-gcp (identifiers, not secrets).
hcp_organization_id = "org-yBViNy2DH4eQsxpp"
hcp_workspace_id    = "ws-MXZMUJEZoC3ki9nN"

# github.com/timlim24/NewProject (gh api repos/timlim24/NewProject --jq '.id, .owner.id')
github_repository_id       = "1392415614"
github_repository_owner_id = "157886626"
