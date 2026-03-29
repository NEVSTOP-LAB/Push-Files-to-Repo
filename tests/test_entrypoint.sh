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
sed -E 's/^[[:space:]]*main[[:space:]]+"\$@"[[:space:]]*(#.*)?$/if [[ -z ${UNIT_TESTING:-} ]]; then main "$@"; fi/' "${REPO_ROOT}/entrypoint.sh" > "${TEMP_SCRIPT}"
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

  # Mock git checkout
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

  # Mock git checkout
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
  local src_dir dest_dir work_dir
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
