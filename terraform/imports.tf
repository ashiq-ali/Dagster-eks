# Terraform import blocks — adopt resources that exist before Terraform runs.
# These are idempotent: safe to leave in permanently.

# ── Bootstrap-created resources ───────────────────────────────────────────────
# bootstrap.sh creates the GitHub Actions IAM role so the FIRST Terraform run
# can authenticate via OIDC. Terraform then imports and manages it going forward.
# This import MUST stay here permanently — remove only if you stop using bootstrap.

import {
  to = module.github_oidc.aws_iam_role.github_actions
  id = "hydrosat-github-actions-role"
}
