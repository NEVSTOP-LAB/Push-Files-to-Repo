# Research & Design Document

## Push-Files-to-Repo GitHub Action

### 1. Overview

This document records the research and design process for the **Push-Files-to-Repo** GitHub Action. The action copies files (or folders) from a source GitHub repository and submits them via Pull Request to a target GitHub repository.

---

### 2. Research

#### 2.1 Existing Solutions

| Action | Approach | Limitations |
|--------|----------|-------------|
| [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) | Full-featured PR creation within or across repos | Heavy dependency; primarily designed for same-repo changes |
| [cpina/github-action-push-to-another-repository](https://github.com/cpina/github-action-push-to-another-repository) | Push directly (not PR-based) | No PR workflow – pushes directly to branch |
| [actions/checkout](https://github.com/actions/checkout) | Official checkout action | Building block only – no PR creation |

**Conclusion**: No existing lightweight action combines "copy specific files/folders" + "create a PR in another repo" as a single step. This action fills that gap.

#### 2.2 Authentication & Permissions

Cross-repository operations **cannot** use the default `GITHUB_TOKEN` because it is scoped to the current repository only. Three authentication methods were evaluated:

| Method | Cross-repo | Granularity | Triggers Workflows | Setup Complexity |
|--------|-----------|-------------|--------------------| ----------------|
| `GITHUB_TOKEN` | ❌ No | Repository-scoped | ❌ No | ✅ None |
| Classic PAT | ✅ Yes | ❌ All repos | ✅ Yes | ✅ Simple |
| Fine-grained PAT | ✅ Yes | ✅ Per-repo | ✅ Yes | ✅ Moderate |
| GitHub App Token | ✅ Yes | ✅ Per-repo | ✅ Yes | ❌ Complex |

**Recommendation**: 
- **Development / Personal use**: Fine-grained PAT with `Contents: Read & Write` and `Pull Requests: Read & Write` on the target repository.
- **Production / Organization**: GitHub App token via [actions/create-github-app-token](https://github.com/actions/create-github-app-token).

##### Required Token Permissions

| Permission | Scope | Reason |
|-----------|-------|--------|
| `Contents` | Read & Write | Clone repo, create branch, push commits |
| `Pull Requests` | Read & Write | Create Pull Request via API |
| `Workflows` | Read & Write | Only if the PR modifies `.github/workflows/` files |

##### How to Create a Fine-grained PAT

1. Go to **GitHub Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens**
2. Click **Generate new token**
3. Set token name, expiration, and description
4. Under **Repository access**, select **Only select repositories** and choose the target repository
5. Under **Permissions → Repository permissions**:
   - `Contents`: **Read and write**
   - `Pull requests`: **Read and write**
6. Click **Generate token** and store it as a repository secret

##### How to Use a GitHub App Token

1. Create a GitHub App with the permissions listed above
2. Install the app on the target repository
3. Store the App ID and private key as secrets
4. Use `actions/create-github-app-token@v2` to generate a token in the workflow

```yaml
- uses: actions/create-github-app-token@v2
  id: app-token
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: target-owner
    repositories: target-repo
```

#### 2.3 GitHub API for Pull Request Creation

The [Create a pull request](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request) endpoint is used:

```
POST /repos/{owner}/{repo}/pulls
```

**Required fields**:
- `title` – PR title
- `head` – source branch name
- `base` – target branch name
- `body` – PR description

**Optional fields**:
- `draft` – boolean, create as draft PR

**Error handling**:
- `422` with message "A pull request already exists" – idempotent handling
- `404` – repository not found or token lacks access
- `403` – insufficient permissions

#### 2.4 Git Operations

The action uses standard git CLI commands:

1. `git clone --depth=1` – shallow clone for efficiency
2. `git checkout -b` – create a new branch
3. `git add -A` – stage all changes
4. `git diff --cached --quiet` – detect if there are actual changes
5. `git commit` – commit with configurable message
6. `git push` – push branch to remote

Authentication for git operations uses the `x-access-token` URL scheme:
```
https://x-access-token:<TOKEN>@github.com/owner/repo.git
```

#### 2.5 Security Considerations

1. **Token in clone URL**: The token is embedded in the clone URL which is a standard pattern for GitHub Actions. The clone directory is created in a temp folder and cleaned up after execution.
2. **No token logging**: The script does not echo the token. GitHub Actions automatically masks secrets in logs.
3. **Temporary directory cleanup**: Uses `trap cleanup EXIT` to ensure temp directories are removed.
4. **Input validation**: All required inputs are validated before any git operations.

---

### 3. Design

#### 3.1 Architecture

```
┌─────────────────────────────────────────────────────┐
│  GitHub Actions Workflow (Source Repo)               │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Push-Files-to-Repo Action                    │  │
│  │                                               │  │
│  │  1. Validate inputs                           │  │
│  │  2. Resolve source file/folder path           │  │
│  │  3. Clone target repo (shallow, base branch)  │  │
│  │  4. Create head branch                        │  │
│  │  5. Copy files from source to target          │  │
│  │  6. Commit & push changes                     │  │
│  │  7. Create PR via GitHub REST API             │  │
│  │  8. Output PR number and URL                  │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
└─────────────────────────────────────────────────────┘
          │                           │
          ▼                           ▼
  ┌──────────────┐           ┌──────────────────┐
  │ Source Repo  │           │ Target Repo      │
  │ (files)      │           │ (PR created)     │
  └──────────────┘           └──────────────────┘
```

#### 3.2 Action Type: Composite

The action is implemented as a **composite action** (`runs: using: composite`) with a bash entrypoint script. Rationale:

- **No build step required** – unlike JavaScript actions, no compilation or bundling needed
- **Portable** – bash is available on all GitHub-hosted runners
- **Dependencies** – relies only on `git`, `curl`, `jq` (all pre-installed on runners)
- **Maintainable** – single shell script, easy to read and debug

#### 3.3 Input/Output Design

**Inputs** (see `action.yml` for full details):

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `source_folder` | ✅ | – | Path to source file/folder |
| `destination_repo` | ✅ | – | Target repo (`owner/repo`) |
| `destination_folder` | ❌ | `.` | Target path in repo |
| `destination_base_branch` | ❌ | `main` | Base branch for PR |
| `destination_head_branch` | ❌ | auto-generated | Branch name for PR |
| `token` | ✅ | – | PAT or App token |
| `commit_message` | ❌ | auto | Commit message |
| `pr_title` | ❌ | auto | PR title |
| `pr_body` | ❌ | auto | PR body |
| `git_user_name` | ❌ | `github-actions[bot]` | Committer name |
| `git_user_email` | ❌ | bot email | Committer email |
| `cleanup` | ❌ | `false` | Remove existing files first |
| `draft` | ❌ | `false` | Create draft PR |

**Outputs**:

| Output | Description |
|--------|-------------|
| `pr_number` | The PR number |
| `pr_url` | The PR URL |

#### 3.4 Error Handling

| Scenario | Behavior |
|----------|----------|
| Missing required inputs | Exit with error message |
| Source path doesn't exist | Exit with error |
| Invalid `destination_repo` format | Exit with error |
| No changes detected | Warning + skip PR creation |
| PR already exists for branch | Warning + return existing PR info |
| API failure | Exit with HTTP code and error body |

#### 3.5 Branch Naming

When `destination_head_branch` is not specified, the action generates a unique branch name:

```
push-files/YYYYMMDD-HHMMSS-RANDOM
```

This avoids conflicts when the action runs multiple times.

---

### 4. Testing Strategy

Tests are organized into:

1. **Unit tests** (`tests/test_entrypoint.sh`) – test individual functions in isolation using a mock environment
2. **Integration test workflow** (`.github/workflows/test.yml`) – end-to-end test in a real GitHub Actions environment

See the `tests/` directory for implementation details.

---

### 5. References

- [GitHub Actions: Creating a composite action](https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action)
- [GitHub REST API: Create a pull request](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request)
- [GitHub: Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub: Creating a GitHub App](https://docs.github.com/en/apps/creating-github-apps)
- [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request)
- [actions/checkout](https://github.com/actions/checkout)
