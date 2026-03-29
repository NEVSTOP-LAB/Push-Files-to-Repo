#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Push Files to Repo - Entrypoint Script
#
# This script copies files from a source folder in the current repository to a
# target repository, creates a branch, commits the changes, pushes, and opens
# a Pull Request via the GitHub API.
###############################################################################

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info()  { echo "::group::$1"; }
log_end()   { echo "::endgroup::"; }
log_error() { echo "::error::$1"; }

# ---------------------------------------------------------------------------
# Mask the token so it never appears in logs
# ---------------------------------------------------------------------------

mask_token() {
  if [[ -n "${INPUT_TOKEN:-}" ]]; then
    # Register the token with GitHub Actions log masking.
    # Any occurrence of this value in subsequent log output will be replaced
    # with '***'.
    echo "::add-mask::${INPUT_TOKEN}"
  fi
}

# ---------------------------------------------------------------------------
# Validate required inputs
# ---------------------------------------------------------------------------

validate_inputs() {
  local missing=0

  if [[ -z "${INPUT_SOURCE_FOLDER:-}" ]]; then
    log_error "Input 'source_folder' is required."
    missing=1
  fi

  if [[ -z "${INPUT_DESTINATION_REPO:-}" ]]; then
    log_error "Input 'destination_repo' is required."
    missing=1
  fi

  if [[ -z "${INPUT_TOKEN:-}" ]]; then
    log_error "Input 'token' is required."
    missing=1
  fi

  # Validate destination_repo format (owner/repo)
  if [[ -n "${INPUT_DESTINATION_REPO:-}" ]] && ! echo "${INPUT_DESTINATION_REPO}" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    log_error "Input 'destination_repo' must be in 'owner/repo' format. Got: ${INPUT_DESTINATION_REPO}"
    missing=1
  fi

  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Resolve source files
# ---------------------------------------------------------------------------

resolve_source_files() {
  SOURCE_FOLDER="${INPUT_SOURCE_FOLDER}"

  # Resolve relative to GITHUB_WORKSPACE if set, otherwise current directory
  local base_dir="${GITHUB_WORKSPACE:-.}"

  if [[ ! "${SOURCE_FOLDER}" = /* ]]; then
    SOURCE_FOLDER="${base_dir}/${SOURCE_FOLDER}"
  fi

  if [[ ! -e "${SOURCE_FOLDER}" ]]; then
    log_error "Source path does not exist: ${SOURCE_FOLDER}"
    exit 1
  fi

  echo "Source path resolved to: ${SOURCE_FOLDER}"
}

# ---------------------------------------------------------------------------
# Clone target repository
# ---------------------------------------------------------------------------

clone_target_repo() {
  DEST_BASE_BRANCH="${INPUT_DESTINATION_BASE_BRANCH:-main}"
  CLONE_DIR=$(mktemp -d)

  echo "Cloning ${INPUT_DESTINATION_REPO} (branch: ${DEST_BASE_BRANCH}) into ${CLONE_DIR} ..."

  # Use http.extraheader for authentication instead of embedding the token in
  # the URL.  This prevents the token from leaking into log output, git remote
  # config, or error messages.
  local auth_header
  auth_header=$(echo -n "x-access-token:${INPUT_TOKEN}" | base64 | tr -d '\n')

  # Mask the derived credential as well
  echo "::add-mask::${auth_header}"

  # Clone with auth via extraheader. Capture exit code separately so that a
  # genuine clone failure is not silently swallowed by the output filter.
  local clone_log clone_rc=0
  clone_log=$(git -c "http.extraheader=Authorization: Basic ${auth_header}" \
    clone \
    --depth=1 \
    --branch="${DEST_BASE_BRANCH}" \
    "https://github.com/${INPUT_DESTINATION_REPO}.git" \
    "${CLONE_DIR}" 2>&1) || clone_rc=$?

  # Print the log with any credential values stripped out
  if [[ -n "${clone_log}" ]]; then
    echo "${clone_log}" | grep -F -v -e "${INPUT_TOKEN}" -e "${auth_header}" || true
  fi

  if [[ "${clone_rc}" -ne 0 ]]; then
    log_error "git clone failed (exit code ${clone_rc})."
    exit 1
  fi

  cd "${CLONE_DIR}"

  # Persist the credential via extraheader so that subsequent push commands
  # work without embedding the token in the remote URL.
  git config http.extraheader "Authorization: Basic ${auth_header}"

  git config user.name  "${INPUT_GIT_USER_NAME:-github-actions[bot]}"
  git config user.email "${INPUT_GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
}

# ---------------------------------------------------------------------------
# Create a unique head branch
# ---------------------------------------------------------------------------

create_head_branch() {
  if [[ -n "${INPUT_DESTINATION_HEAD_BRANCH:-}" ]]; then
    HEAD_BRANCH="${INPUT_DESTINATION_HEAD_BRANCH}"
  else
    HEAD_BRANCH="push-files/$(date +%Y%m%d-%H%M%S)-${RANDOM}"
  fi

  echo "Creating branch: ${HEAD_BRANCH}"
  git checkout -b "${HEAD_BRANCH}"
}

# ---------------------------------------------------------------------------
# Copy files to destination
# ---------------------------------------------------------------------------

copy_files() {
  local dest_folder="${INPUT_DESTINATION_FOLDER:-.}"

  # Create destination directory if it doesn't exist
  mkdir -p "${dest_folder}"

  # Optionally clean the destination folder first
  if [[ "${INPUT_CLEANUP:-false}" == "true" ]]; then
    echo "Cleanup enabled – removing existing files in '${dest_folder}'"
    # Remove everything except .git in the destination folder
    find "${dest_folder}" -mindepth 1 -not -path './.git/*' -not -name '.git' -delete 2>/dev/null || true
  fi

  # Copy files
  if [[ -d "${SOURCE_FOLDER}" ]]; then
    # Source is a directory – copy its contents
    cp -r "${SOURCE_FOLDER}/." "${dest_folder}/"
  else
    # Source is a single file
    cp "${SOURCE_FOLDER}" "${dest_folder}/"
  fi

  echo "Files copied to '${dest_folder}'."
}

# ---------------------------------------------------------------------------
# Commit & push changes
# ---------------------------------------------------------------------------

commit_and_push() {
  git add -A

  # Check if there are changes to commit
  if git diff --cached --quiet; then
    echo "::warning::No changes detected. Skipping PR creation."
    echo "pr_number=" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "pr_url=" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi

  git commit -m "${INPUT_COMMIT_MESSAGE:-chore: push files from source repository}"
  git push origin "${HEAD_BRANCH}"

  echo "Changes pushed to ${INPUT_DESTINATION_REPO}@${HEAD_BRANCH}."
}

# ---------------------------------------------------------------------------
# Create Pull Request via GitHub REST API
# ---------------------------------------------------------------------------

create_pull_request() {
  local draft_flag="false"
  if [[ "${INPUT_DRAFT:-false}" == "true" ]]; then
    draft_flag="true"
  fi

  local api_url="https://api.github.com/repos/${INPUT_DESTINATION_REPO}/pulls"

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "$(jq -n \
      --arg title "${INPUT_PR_TITLE:-[Automated] Push files from source repository}" \
      --arg body  "${INPUT_PR_BODY:-Automated PR created by Push-Files-to-Repo action.}" \
      --arg head  "${HEAD_BRANCH}" \
      --arg base  "${DEST_BASE_BRANCH}" \
      --argjson draft "${draft_flag}" \
      '{title: $title, body: $body, head: $head, base: $base, draft: $draft}')" \
    "${api_url}")

  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    # Check if a PR already exists (422 with "A pull request already exists")
    if echo "${body}" | grep -q "A pull request already exists"; then
      echo "::warning::A pull request already exists for branch '${HEAD_BRANCH}'."

      # Derive the destination owner from "owner/repo"
      local dest_owner
      dest_owner=$(printf '%s\n' "${INPUT_DESTINATION_REPO}" | cut -d'/' -f1)

      # Query GitHub for the existing PR on this branch
      local list_response
      list_response=$(curl -s \
        -H "Authorization: token ${INPUT_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${INPUT_DESTINATION_REPO}/pulls?head=${dest_owner}:${HEAD_BRANCH}&state=open")

      local existing_number existing_url
      existing_number=$(echo "${list_response}" | jq -r '.[0].number // empty')
      existing_url=$(echo "${list_response}" | jq -r '.[0].html_url // empty')

      if [[ -z "${existing_number}" || -z "${existing_url}" ]]; then
        echo "::warning::Unable to determine existing Pull Request details for branch '${HEAD_BRANCH}'."
      fi

      echo "pr_number=${existing_number}" >> "${GITHUB_OUTPUT:-/dev/null}"
      echo "pr_url=${existing_url}" >> "${GITHUB_OUTPUT:-/dev/null}"
      return 0
    fi

    log_error "Failed to create Pull Request. HTTP ${http_code}: ${body}"
    exit 1
  fi

  local pr_number pr_url
  pr_number=$(echo "${body}" | jq -r '.number')
  pr_url=$(echo "${body}" | jq -r '.html_url')

  echo "Pull Request created: #${pr_number} – ${pr_url}"
  echo "pr_number=${pr_number}" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "pr_url=${pr_url}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ---------------------------------------------------------------------------
# Cleanup temp directory
# ---------------------------------------------------------------------------

cleanup() {
  if [[ -n "${CLONE_DIR:-}" && -d "${CLONE_DIR}" ]]; then
    # Remove credentials from git config before deleting the directory
    git -C "${CLONE_DIR}" config --unset-all http.extraheader 2>/dev/null || true
    rm -rf "${CLONE_DIR}"
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log_info "Masking token"
  mask_token
  log_end

  log_info "Validating inputs"
  validate_inputs
  log_end

  log_info "Resolving source files"
  resolve_source_files
  log_end

  log_info "Cloning target repository"
  clone_target_repo
  log_end

  log_info "Creating head branch"
  create_head_branch
  log_end

  log_info "Copying files"
  copy_files
  log_end

  log_info "Committing and pushing changes"
  commit_and_push
  log_end

  log_info "Creating Pull Request"
  create_pull_request
  log_end

  echo "✅ Done!"
}

main "$@"
