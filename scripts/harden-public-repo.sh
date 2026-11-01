#!/usr/bin/env bash
# Run once right after Codebater/folio is made public. Both settings exist
# only for public repositories (the API refuses them while it is private).
#   - Secret scanning with push protection: a push containing a recognisable
#     key or token is blocked before it lands.
#   - Workflows from outside contributors' forks wait for approval.
# Signing secrets are already safe: they live in the "testflight"
# environment, which only the main branch may use, and GitHub never passes
# secrets to workflows started from forks.
set -euo pipefail
repo="${1:-Codebater/folio}"

test "$(gh repo view "$repo" --json visibility --jq .visibility)" = "PUBLIC" \
  || { echo "$repo is not public yet; nothing to do." >&2; exit 1; }

gh api -X PATCH "repos/$repo" --input - <<'JSON' >/dev/null
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
echo '{"approval_policy":"all_external_contributors"}' \
  | gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" --input - >/dev/null

gh api "repos/$repo" --jq '"secret scanning: \(.security_and_analysis.secret_scanning.status), push protection: \(.security_and_analysis.secret_scanning_push_protection.status)"'
gh api "repos/$repo/actions/permissions/fork-pr-contributor-approval" --jq '"fork workflows need approval for: \(.approval_policy)"'
gh api "repos/$repo/environments/testflight/deployment-branch-policies" --jq '"testflight secrets usable from: \([.branch_policies[].name] | join(", "))"'
