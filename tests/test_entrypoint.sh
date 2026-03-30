#!/usr/bin/env bash
###############################################################################
# Unit Tests for entrypoint.sh
#
# These tests source the entrypoint script functions and verify them
# in isolation using a mocked environment.
#
# Usage: bash tests/test_entrypoint.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Test framework (minimal)
# ---------------------------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  ❌ FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    echo "         $2"
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assertion}"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${msg}"
  else
    fail "${msg}" "Expected '${expected}', got '${actual}'"
  fi
}

assert_exit_code() {
  local expected_code="$1"
  shift
  local actual_code=0
  # Run in a subshell so that exit does not kill the test runner
  ( "$@" ) 2>/dev/null || actual_code=$?
  if [[ "${expected_code}" -eq "${actual_code}" ]]; then
    pass "exit code ${expected_code}: $*"
  else
    fail "exit code ${expected_code}: $*" "Got exit code ${actual_code}"
  fi
}

summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Tests: ${TESTS_RUN} | Passed: ${TESTS_PASSED} | Failed: ${TESTS_FAILED}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "${TESTS_FAILED}" -gt 0 ]]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Source functions from entrypoint.sh (without running main)
# We extract functions by sourcing a modified version
# ---------------------------------------------------------------------------

# Create a temp copy and guard the final main call so it doesn't run in tests
TEMP_SCRIPT=$(mktemp)
# Ensure entrypoint.sh can detect that it's being run under unit tests
export UNIT_TESTING=1
# Replace a standalone 'main "$@"' call (with optional whitespace/comments)
# with an environment-guarded invocation so sourcing does not execute main.
# shellcheck disable=SC2016
sed -E 's/^[[:space:]]*main[[:space:]]+"\$@"[[:space:]]*(#.*)?$/if [[ -z ${UNIT_TESTING:-} ]]; then main "$@"; fi/' "${REPO_ROOT}/entrypoint.sh" > "${TEMP_SCRIPT}"
# shellcheck disable=SC1090
source "${TEMP_SCRIPT}"
rm -f "${TEMP_SCRIPT}"

# ---------------------------------------------------------------------------
# Mock GITHUB_OUTPUT
# ---------------------------------------------------------------------------

MOCK_OUTPUT=$(mktemp)
export GITHUB_OUTPUT="${MOCK_OUTPUT}"

cleanup_mock() {
  rm -f "${MOCK_OUTPUT}"
}
trap cleanup_mock EXIT

# ============================================================================
# TEST SUITE: mask_token (secret protection)
# ============================================================================

echo ""
echo "🧪 Test Suite: mask_token (secret protection)"
echo "──────────────────────────────────────────────────────────"

# Test: mask_token emits ::add-mask:: command
test_mask_token_emits_mask() {
  export INPUT_TOKEN="ghp_supersecrettoken123"
  local output
  output=$(mask_token 2>&1)
  if echo "${output}" | grep -qF "::add-mask::ghp_supersecrettoken123"; then
    pass "mask_token emits ::add-mask:: with token value"
  else
    fail "mask_token emits ::add-mask:: with token value" "Output: ${output}"
  fi
  unset INPUT_TOKEN
}
test_mask_token_emits_mask

# Test: mask_token does not emit when token is empty
test_mask_token_empty_token() {
  export INPUT_TOKEN=""
  local output
  output=$(mask_token 2>&1)
  if echo "${output}" | grep -qF "::add-mask::"; then
    fail "mask_token should not emit ::add-mask:: when token is empty"
  else
    pass "mask_token skips masking when token is empty"
  fi
  unset INPUT_TOKEN
}
test_mask_token_empty_token

# Test: entrypoint.sh calls mask_token before other operations
test_entrypoint_masks_before_validate() {
  if grep -n "mask_token" "${REPO_ROOT}/entrypoint.sh" | head -n1 | grep -q "mask_token"; then
    local mask_line validate_line
    mask_line=$(grep -n "mask_token$" "${REPO_ROOT}/entrypoint.sh" | head -n1 | cut -d: -f1)
    validate_line=$(grep -n "validate_inputs$" "${REPO_ROOT}/entrypoint.sh" | head -n1 | cut -d: -f1)
    if [[ -n "${mask_line}" ]] && [[ -n "${validate_line}" ]] && [[ "${mask_line}" -lt "${validate_line}" ]]; then
      pass "mask_token is called before validate_inputs in main()"
    else
      fail "mask_token is called before validate_inputs in main()" "mask_token at line ${mask_line}, validate_inputs at line ${validate_line}"
    fi
  else
    fail "mask_token is called in entrypoint.sh"
  fi
}
test_entrypoint_masks_before_validate

# Test: git clone URL does NOT contain the token
test_no_token_in_clone_url() {
  if grep -q 'x-access-token:.*INPUT_TOKEN.*github.com' "${REPO_ROOT}/entrypoint.sh"; then
    fail "Token is not embedded in git clone URL" "Found token in clone URL pattern"
  else
    pass "Token is not embedded in git clone URL"
  fi
}
test_no_token_in_clone_url

# Test: http.extraheader is used for authentication
test_uses_extraheader_auth() {
  if grep -q 'http.extraheader' "${REPO_ROOT}/entrypoint.sh"; then
    pass "Uses http.extraheader for git authentication"
  else
    fail "Uses http.extraheader for git authentication"
  fi
}
test_uses_extraheader_auth

# Test: cleanup removes credentials from git config
test_cleanup_removes_credentials() {
  if grep -q 'config --unset-all http.extraheader' "${REPO_ROOT}/entrypoint.sh"; then
    pass "Cleanup removes http.extraheader credentials"
  else
    fail "Cleanup removes http.extraheader credentials"
  fi
}
test_cleanup_removes_credentials

# ============================================================================
# TEST SUITE: validate_inputs
# ============================================================================

echo ""
echo "🧪 Test Suite: validate_inputs"
echo "──────────────────────────────────────────────────────────"

# Test: All required inputs present
test_validate_inputs_success() {
  export INPUT_SOURCE_FOLDER="src/"
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_TOKEN="ghp_test123"

  local rc=0
  ( validate_inputs ) 2>/dev/null || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    pass "All required inputs present – no error"
  else
    fail "All required inputs present – no error" "Exit code: ${rc}"
  fi

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_success

# Test: Missing source_folder
test_validate_inputs_missing_source() {
  export INPUT_SOURCE_FOLDER=""
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_TOKEN="ghp_test123"

  assert_exit_code 1 validate_inputs

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_missing_source

# Test: Missing token
test_validate_inputs_missing_token() {
  export INPUT_SOURCE_FOLDER="src/"
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_TOKEN=""

  assert_exit_code 1 validate_inputs

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_missing_token

# Test: Missing destination_repo
test_validate_inputs_missing_dest() {
  export INPUT_SOURCE_FOLDER="src/"
  export INPUT_DESTINATION_REPO=""
  export INPUT_TOKEN="ghp_test123"

  assert_exit_code 1 validate_inputs

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_missing_dest

# Test: Invalid destination_repo format
test_validate_inputs_bad_repo_format() {
  export INPUT_SOURCE_FOLDER="src/"
  export INPUT_DESTINATION_REPO="invalid-format"
  export INPUT_TOKEN="ghp_test123"

  assert_exit_code 1 validate_inputs

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_bad_repo_format

# Test: Valid repo format with dots, dashes, underscores
test_validate_inputs_complex_repo_name() {
  export INPUT_SOURCE_FOLDER="src/"
  export INPUT_DESTINATION_REPO="my-org.name/my_repo.name-v2"
  export INPUT_TOKEN="ghp_test123"

  local rc=0
  ( validate_inputs ) 2>/dev/null || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    pass "Complex repo name accepted"
  else
    fail "Complex repo name accepted" "Exit code: ${rc}"
  fi

  unset INPUT_SOURCE_FOLDER INPUT_DESTINATION_REPO INPUT_TOKEN
}
test_validate_inputs_complex_repo_name

# ============================================================================
# TEST SUITE: resolve_source_files
# ============================================================================

echo ""
echo "🧪 Test Suite: resolve_source_files"
echo "──────────────────────────────────────────────────────────"

# Test: Resolve relative path with GITHUB_WORKSPACE
test_resolve_source_relative() {
  local test_dir
  test_dir=$(mktemp -d)
  mkdir -p "${test_dir}/myfiles"
  touch "${test_dir}/myfiles/test.txt"

  export INPUT_SOURCE_FOLDER="myfiles"
  export GITHUB_WORKSPACE="${test_dir}"

  # Run in subshell, capture SOURCE_FOLDER via a temp file
  local result_file
  result_file=$(mktemp)
  ( resolve_source_files >/dev/null 2>&1; echo "${SOURCE_FOLDER}" > "${result_file}" )
  local resolved
  resolved=$(cat "${result_file}")
  rm -f "${result_file}"

  assert_eq "${test_dir}/myfiles" "${resolved}" "Relative path resolved with GITHUB_WORKSPACE"

  rm -rf "${test_dir}"
  unset INPUT_SOURCE_FOLDER GITHUB_WORKSPACE SOURCE_FOLDER
}
test_resolve_source_relative

# Test: Resolve absolute path
test_resolve_source_absolute() {
  local test_dir
  test_dir=$(mktemp -d)
  touch "${test_dir}/file.txt"

  export INPUT_SOURCE_FOLDER="${test_dir}/file.txt"
  unset GITHUB_WORKSPACE 2>/dev/null || true

  local result_file
  result_file=$(mktemp)
  ( resolve_source_files >/dev/null 2>&1; echo "${SOURCE_FOLDER}" > "${result_file}" )
  local resolved
  resolved=$(cat "${result_file}")
  rm -f "${result_file}"

  assert_eq "${test_dir}/file.txt" "${resolved}" "Absolute path preserved"

  rm -rf "${test_dir}"
  unset INPUT_SOURCE_FOLDER SOURCE_FOLDER
}
test_resolve_source_absolute

# Test: Non-existent path
test_resolve_source_nonexistent() {
  export INPUT_SOURCE_FOLDER="/nonexistent/path/that/does/not/exist"
  unset GITHUB_WORKSPACE 2>/dev/null || true
  assert_exit_code 1 resolve_source_files

  unset INPUT_SOURCE_FOLDER SOURCE_FOLDER
}
test_resolve_source_nonexistent

# ============================================================================
# TEST SUITE: create_head_branch
# ============================================================================

echo ""
echo "🧪 Test Suite: create_head_branch (branch name generation)"
echo "──────────────────────────────────────────────────────────"

# We can't actually run git commands here, but we can test the logic
# by overriding git with a no-op

# Test: Custom branch name
test_branch_custom_name() {
  export INPUT_DESTINATION_HEAD_BRANCH="my-custom-branch"

  # Mock git checkout (invoked indirectly via create_head_branch)
  # shellcheck disable=SC2317
  git() { true; }
  export -f git

  create_head_branch >/dev/null 2>&1
  assert_eq "my-custom-branch" "${HEAD_BRANCH}" "Custom branch name used"

  unset -f git
  unset INPUT_DESTINATION_HEAD_BRANCH HEAD_BRANCH
}
test_branch_custom_name

# Test: Auto-generated branch name
test_branch_auto_name() {
  export INPUT_DESTINATION_HEAD_BRANCH=""

  # Mock git checkout (invoked indirectly via create_head_branch)
  # shellcheck disable=SC2317
  git() { true; }
  export -f git

  create_head_branch >/dev/null 2>&1

  if [[ "${HEAD_BRANCH}" =~ ^push-files/[0-9]{8}-[0-9]{6}-[0-9]+$ ]]; then
    pass "Auto-generated branch name matches pattern"
  else
    fail "Auto-generated branch name matches pattern" "Got: ${HEAD_BRANCH}"
  fi

  unset -f git
  unset INPUT_DESTINATION_HEAD_BRANCH HEAD_BRANCH
}
test_branch_auto_name

# ============================================================================
# TEST SUITE: copy_files
# ============================================================================

echo ""
echo "🧪 Test Suite: copy_files"
echo "──────────────────────────────────────────────────────────"

# Test: Copy directory contents
test_copy_directory() {
  local src_dir work_dir
  src_dir=$(mktemp -d)
  work_dir=$(mktemp -d)

  # Create source files
  mkdir -p "${src_dir}/subdir"
  echo "file1" > "${src_dir}/file1.txt"
  echo "file2" > "${src_dir}/subdir/file2.txt"

  # Setup variables
  SOURCE_FOLDER="${src_dir}"
  export INPUT_DESTINATION_FOLDER="target"
  export INPUT_CLEANUP="false"

  cd "${work_dir}"
  copy_files >/dev/null 2>&1

  if [[ -f "${work_dir}/target/file1.txt" ]] && [[ -f "${work_dir}/target/subdir/file2.txt" ]]; then
    pass "Directory contents copied correctly"
  else
    fail "Directory contents copied correctly" "Files not found in destination"
  fi

  rm -rf "${src_dir}" "${work_dir}"
  unset SOURCE_FOLDER INPUT_DESTINATION_FOLDER INPUT_CLEANUP
}
test_copy_directory

# Test: Copy single file
test_copy_single_file() {
  local src_file work_dir
  src_file=$(mktemp)
  echo "hello" > "${src_file}"
  work_dir=$(mktemp -d)

  SOURCE_FOLDER="${src_file}"
  export INPUT_DESTINATION_FOLDER="output"
  export INPUT_CLEANUP="false"

  cd "${work_dir}"
  copy_files >/dev/null 2>&1

  local filename
  filename=$(basename "${src_file}")
  if [[ -f "${work_dir}/output/${filename}" ]]; then
    pass "Single file copied correctly"
  else
    fail "Single file copied correctly" "File not found in destination"
  fi

  rm -f "${src_file}"
  rm -rf "${work_dir}"
  unset SOURCE_FOLDER INPUT_DESTINATION_FOLDER INPUT_CLEANUP
}
test_copy_single_file

# Test: Cleanup mode
test_copy_with_cleanup() {
  local src_dir work_dir
  src_dir=$(mktemp -d)
  work_dir=$(mktemp -d)

  echo "new" > "${src_dir}/new.txt"

  # Pre-populate destination
  mkdir -p "${work_dir}/dest"
  echo "old" > "${work_dir}/dest/old.txt"

  SOURCE_FOLDER="${src_dir}"
  export INPUT_DESTINATION_FOLDER="dest"
  export INPUT_CLEANUP="true"

  cd "${work_dir}"
  # Need to init a git repo for the .git exclusion logic
  git init -q
  copy_files >/dev/null 2>&1

  if [[ -f "${work_dir}/dest/new.txt" ]] && [[ ! -f "${work_dir}/dest/old.txt" ]]; then
    pass "Cleanup mode: old files removed, new files added"
  else
    fail "Cleanup mode: old files removed, new files added" \
         "new.txt exists: $(test -f "${work_dir}/dest/new.txt" && echo yes || echo no), old.txt exists: $(test -f "${work_dir}/dest/old.txt" && echo yes || echo no)"
  fi

  rm -rf "${src_dir}" "${work_dir}"
  unset SOURCE_FOLDER INPUT_DESTINATION_FOLDER INPUT_CLEANUP
}
test_copy_with_cleanup

# Test: Copy to root (destination_folder = ".")
test_copy_to_root() {
  local src_dir work_dir
  src_dir=$(mktemp -d)
  work_dir=$(mktemp -d)

  echo "root-file" > "${src_dir}/root.txt"

  SOURCE_FOLDER="${src_dir}"
  export INPUT_DESTINATION_FOLDER="."
  export INPUT_CLEANUP="false"

  cd "${work_dir}"
  copy_files >/dev/null 2>&1

  if [[ -f "${work_dir}/root.txt" ]]; then
    pass "Copy to root directory works"
  else
    fail "Copy to root directory works"
  fi

  rm -rf "${src_dir}" "${work_dir}"
  unset SOURCE_FOLDER INPUT_DESTINATION_FOLDER INPUT_CLEANUP
}
test_copy_to_root

# Test: Copy directory excludes .git
test_copy_excludes_git() {
  local src_dir work_dir
  src_dir=$(mktemp -d)
  work_dir=$(mktemp -d)

  # Create source with a .git directory (simulating repo root as source)
  mkdir -p "${src_dir}/.git/objects"
  echo "ref: refs/heads/main" > "${src_dir}/.git/HEAD"
  echo "content" > "${src_dir}/file.txt"

  SOURCE_FOLDER="${src_dir}"
  export INPUT_DESTINATION_FOLDER="dest"
  export INPUT_CLEANUP="false"

  cd "${work_dir}"
  copy_files >/dev/null 2>&1

  if [[ -f "${work_dir}/dest/file.txt" ]] && [[ ! -d "${work_dir}/dest/.git" ]]; then
    pass "Copy directory excludes .git"
  else
    fail "Copy directory excludes .git" \
         "file.txt exists: $(test -f "${work_dir}/dest/file.txt" && echo yes || echo no), .git exists: $(test -d "${work_dir}/dest/.git" && echo yes || echo no)"
  fi

  rm -rf "${src_dir}" "${work_dir}"
  unset SOURCE_FOLDER INPUT_DESTINATION_FOLDER INPUT_CLEANUP
}
test_copy_excludes_git

# ============================================================================
# TEST SUITE: clone_target_repo (mocked)
# ============================================================================

echo ""
echo "🧪 Test Suite: clone_target_repo (mocked)"
echo "──────────────────────────────────────────────────────────"

# Test: GIT_TERMINAL_PROMPT is set to 0
test_clone_sets_git_terminal_prompt() {
  if grep -q 'GIT_TERMINAL_PROMPT=0' "${REPO_ROOT}/entrypoint.sh"; then
    pass "clone_target_repo sets GIT_TERMINAL_PROMPT=0"
  else
    fail "clone_target_repo sets GIT_TERMINAL_PROMPT=0"
  fi
}
test_clone_sets_git_terminal_prompt

# Test: clone_target_repo uses extraheader with Basic auth
test_clone_uses_basic_auth() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_DESTINATION_BASE_BRANCH="main"

  # Mock git to record the arguments it was called with
  local call_log
  call_log=$(mktemp)
  # shellcheck disable=SC2317
  git() {
    echo "$*" >> "${call_log}"
    # For clone (-c ... clone ...), init a real git repo so subsequent git config works
    if [[ "${1:-}" == "-c" && "${3:-}" == "clone" ]]; then
      # The clone target directory is the last argument
      local clone_dir="${!#}"
      command git init -q "${clone_dir}"
    elif [[ "${1:-}" == "config" ]]; then
      command git config "$@"
    fi
    return 0
  }
  export -f git

  ( clone_target_repo >/dev/null 2>&1 ) || true

  if grep -qF "http.extraheader=Authorization: Basic" "${call_log}"; then
    pass "clone_target_repo uses http.extraheader with Basic auth"
  else
    fail "clone_target_repo uses http.extraheader with Basic auth" "$(cat "${call_log}")"
  fi

  rm -f "${call_log}"
  rm -rf "${CLONE_DIR:-}" 2>/dev/null || true
  unset -f git
  unset INPUT_TOKEN INPUT_DESTINATION_REPO INPUT_DESTINATION_BASE_BRANCH CLONE_DIR
}
test_clone_uses_basic_auth

# Test: clone_target_repo fails on clone error
test_clone_fails_on_error() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_DESTINATION_BASE_BRANCH="main"

  # Mock git to fail on clone
  # shellcheck disable=SC2317
  git() {
    if [[ "${1:-}" == "-c" && "${3:-}" == "clone" ]]; then
      return 128
    fi
    return 0
  }
  export -f git

  local rc=0
  ( clone_target_repo >/dev/null 2>&1 ) || rc=$?

  if [[ "${rc}" -ne 0 ]]; then
    pass "clone_target_repo exits on clone failure"
  else
    fail "clone_target_repo exits on clone failure" "Expected non-zero exit, got 0"
  fi

  unset -f git
  rm -rf "${CLONE_DIR:-}" 2>/dev/null || true
  unset INPUT_TOKEN INPUT_DESTINATION_REPO INPUT_DESTINATION_BASE_BRANCH CLONE_DIR
}
test_clone_fails_on_error

# ============================================================================
# TEST SUITE: create_pull_request (mocked)
# ============================================================================

echo ""
echo "🧪 Test Suite: create_pull_request (mocked)"
echo "──────────────────────────────────────────────────────────"

# Test: Successful PR creation sets outputs
test_create_pr_success() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  export INPUT_PR_TITLE="Test PR"
  export INPUT_PR_BODY="Test body"
  export INPUT_DRAFT="false"
  HEAD_BRANCH="test-branch"
  DEST_BASE_BRANCH="main"

  # Reset GITHUB_OUTPUT to capture outputs
  MOCK_OUTPUT=$(mktemp)
  export GITHUB_OUTPUT="${MOCK_OUTPUT}"

  # Mock curl to return a successful PR response
  # shellcheck disable=SC2317
  curl() {
    echo '{"number": 42, "html_url": "https://github.com/owner/repo/pull/42"}'
    echo "201"
  }
  export -f curl

  create_pull_request >/dev/null 2>&1

  local pr_num pr_url
  pr_num=$(grep '^pr_number=' "${MOCK_OUTPUT}" | cut -d= -f2)
  pr_url=$(grep '^pr_url=' "${MOCK_OUTPUT}" | cut -d= -f2)

  if [[ "${pr_num}" == "42" ]] && [[ "${pr_url}" == "https://github.com/owner/repo/pull/42" ]]; then
    pass "Successful PR creation sets correct outputs"
  else
    fail "Successful PR creation sets correct outputs" "pr_number=${pr_num}, pr_url=${pr_url}"
  fi

  rm -f "${MOCK_OUTPUT}"
  unset -f curl
  unset INPUT_TOKEN INPUT_DESTINATION_REPO INPUT_PR_TITLE INPUT_PR_BODY INPUT_DRAFT HEAD_BRANCH DEST_BASE_BRANCH
}
test_create_pr_success

# Test: PR creation uses Bearer auth header
test_create_pr_uses_bearer_auth() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  HEAD_BRANCH="test-branch"
  DEST_BASE_BRANCH="main"
  MOCK_OUTPUT=$(mktemp)
  export GITHUB_OUTPUT="${MOCK_OUTPUT}"

  local curl_args_log
  curl_args_log=$(mktemp)

  # shellcheck disable=SC2317
  curl() {
    echo "$*" >> "${curl_args_log}"
    echo '{"number": 1, "html_url": "https://github.com/owner/repo/pull/1"}'
    echo "201"
  }
  export -f curl

  create_pull_request >/dev/null 2>&1

  if grep -qF "Authorization: Bearer" "${curl_args_log}"; then
    pass "create_pull_request uses Bearer auth header"
  else
    fail "create_pull_request uses Bearer auth header" "$(cat "${curl_args_log}")"
  fi

  rm -f "${curl_args_log}" "${MOCK_OUTPUT}"
  unset -f curl
  unset INPUT_TOKEN INPUT_DESTINATION_REPO HEAD_BRANCH DEST_BASE_BRANCH
}
test_create_pr_uses_bearer_auth

# Test: PR already exists returns gracefully
test_create_pr_already_exists() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  HEAD_BRANCH="existing-branch"
  DEST_BASE_BRANCH="main"
  MOCK_OUTPUT=$(mktemp)
  export GITHUB_OUTPUT="${MOCK_OUTPUT}"

  local curl_counter_file
  curl_counter_file=$(mktemp)
  echo "0" > "${curl_counter_file}"

  # shellcheck disable=SC2317
  curl() {
    local count
    count=$(cat "${curl_counter_file}")
    count=$((count + 1))
    echo "${count}" > "${curl_counter_file}"
    if [[ "${count}" -eq 1 ]]; then
      # First call: POST returns 422 (already exists)
      echo '{"errors":[{"message":"A pull request already exists for owner:existing-branch"}]}'
      echo "422"
    else
      # Second call: GET lists existing PR
      echo '[{"number": 99, "html_url": "https://github.com/owner/repo/pull/99"}]'
    fi
  }
  export -f curl

  local rc=0
  ( create_pull_request >/dev/null 2>&1 ) || rc=$?

  local pr_num
  pr_num=$(grep '^pr_number=' "${MOCK_OUTPUT}" | cut -d= -f2)

  if [[ "${rc}" -eq 0 ]] && [[ "${pr_num}" == "99" ]]; then
    pass "PR already exists: returns existing PR info"
  else
    fail "PR already exists: returns existing PR info" "rc=${rc}, pr_number=${pr_num}"
  fi

  rm -f "${MOCK_OUTPUT}" "${curl_counter_file}"
  unset -f curl
  unset INPUT_TOKEN INPUT_DESTINATION_REPO HEAD_BRANCH DEST_BASE_BRANCH
}
test_create_pr_already_exists

# Test: PR creation failure exits with error
test_create_pr_failure() {
  export INPUT_TOKEN="ghp_testtoken"
  export INPUT_DESTINATION_REPO="owner/repo"
  HEAD_BRANCH="test-branch"
  # Used by create_pull_request (sourced function)
  # shellcheck disable=SC2034
  DEST_BASE_BRANCH="main"
  MOCK_OUTPUT=$(mktemp)
  export GITHUB_OUTPUT="${MOCK_OUTPUT}"

  # shellcheck disable=SC2317
  curl() {
    echo '{"message": "Not Found"}'
    echo "404"
  }
  export -f curl

  local rc=0
  ( create_pull_request >/dev/null 2>&1 ) || rc=$?

  if [[ "${rc}" -ne 0 ]]; then
    pass "PR creation failure exits with error"
  else
    fail "PR creation failure exits with error" "Expected non-zero exit, got 0"
  fi

  rm -f "${MOCK_OUTPUT}"
  unset -f curl
  unset INPUT_TOKEN INPUT_DESTINATION_REPO HEAD_BRANCH DEST_BASE_BRANCH
}
test_create_pr_failure

# ============================================================================
# TEST SUITE: action.yml validation
# ============================================================================

echo ""
echo "🧪 Test Suite: action.yml validation"
echo "──────────────────────────────────────────────────────────"

# Test: action.yml exists and is valid YAML
test_action_yml_exists() {
  if [[ -f "${REPO_ROOT}/action.yml" ]]; then
    pass "action.yml exists"
  else
    fail "action.yml exists"
  fi
}
test_action_yml_exists

# Test: action.yml has required fields
test_action_yml_has_name() {
  if grep -q "^name:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
    pass "action.yml has 'name' field"
  else
    fail "action.yml has 'name' field"
  fi
}
test_action_yml_has_name

test_action_yml_has_description() {
  if grep -q "^description:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
    pass "action.yml has 'description' field"
  else
    fail "action.yml has 'description' field"
  fi
}
test_action_yml_has_description

test_action_yml_has_inputs() {
  if grep -q "^inputs:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
    pass "action.yml has 'inputs' section"
  else
    fail "action.yml has 'inputs' section"
  fi
}
test_action_yml_has_inputs

test_action_yml_has_outputs() {
  if grep -q "^outputs:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
    pass "action.yml has 'outputs' section"
  else
    fail "action.yml has 'outputs' section"
  fi
}
test_action_yml_has_outputs

test_action_yml_has_runs() {
  if grep -q "^runs:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
    pass "action.yml has 'runs' section"
  else
    fail "action.yml has 'runs' section"
  fi
}
test_action_yml_has_runs

# Test: Required inputs are defined
test_action_yml_required_inputs() {
  local all_found=true
  for input in source_folder destination_repo token; do
    if ! grep -q "  ${input}:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
      fail "Required input '${input}' defined in action.yml"
      all_found=false
    fi
  done
  if $all_found; then
    pass "All required inputs defined in action.yml"
  fi
}
test_action_yml_required_inputs

# Test: Optional inputs are defined
test_action_yml_optional_inputs() {
  local all_found=true
  for input in destination_folder destination_base_branch destination_head_branch commit_message pr_title pr_body git_user_name git_user_email cleanup draft; do
    if ! grep -q "  ${input}:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
      fail "Optional input '${input}' defined in action.yml"
      all_found=false
    fi
  done
  if $all_found; then
    pass "All optional inputs defined in action.yml"
  fi
}
test_action_yml_optional_inputs

# Test: Outputs are defined
test_action_yml_outputs_defined() {
  local all_found=true
  for output in pr_number pr_url; do
    if ! grep -q "  ${output}:" "${REPO_ROOT}/action.yml" 2>/dev/null; then
      fail "Output '${output}' defined in action.yml"
      all_found=false
    fi
  done
  if $all_found; then
    pass "All outputs defined in action.yml"
  fi
}
test_action_yml_outputs_defined

# ============================================================================
# TEST SUITE: entrypoint.sh quality
# ============================================================================

echo ""
echo "🧪 Test Suite: entrypoint.sh quality"
echo "──────────────────────────────────────────────────────────"

test_entrypoint_executable() {
  if [[ -x "${REPO_ROOT}/entrypoint.sh" ]]; then
    pass "entrypoint.sh is executable"
  else
    fail "entrypoint.sh is executable"
  fi
}
test_entrypoint_executable

test_entrypoint_has_shebang() {
  local first_line
  first_line=$(head -n1 "${REPO_ROOT}/entrypoint.sh")
  if [[ "${first_line}" == "#!/usr/bin/env bash" ]] || [[ "${first_line}" == "#!/bin/bash" ]]; then
    pass "entrypoint.sh has bash shebang"
  else
    fail "entrypoint.sh has bash shebang" "Got: ${first_line}"
  fi
}
test_entrypoint_has_shebang

test_entrypoint_has_set_euo() {
  if grep -q "set -euo pipefail" "${REPO_ROOT}/entrypoint.sh"; then
    pass "entrypoint.sh uses strict mode (set -euo pipefail)"
  else
    fail "entrypoint.sh uses strict mode (set -euo pipefail)"
  fi
}
test_entrypoint_has_set_euo

test_entrypoint_has_cleanup_trap() {
  if grep -q "trap cleanup EXIT" "${REPO_ROOT}/entrypoint.sh"; then
    pass "entrypoint.sh has cleanup trap"
  else
    fail "entrypoint.sh has cleanup trap"
  fi
}
test_entrypoint_has_cleanup_trap

# Test: shellcheck (if available)
test_shellcheck() {
  if command -v shellcheck &>/dev/null; then
    if shellcheck "${REPO_ROOT}/entrypoint.sh" 2>/dev/null; then
      pass "entrypoint.sh passes shellcheck"
    else
      fail "entrypoint.sh passes shellcheck"
    fi
  else
    echo "  ⏭️  SKIP: shellcheck not installed"
  fi
}
test_shellcheck

# ============================================================================
# Summary
# ============================================================================

summary
