# Implementation Plan: Separate New Relic Agent into Layered Docker Image

## Overview
Separate the New Relic agent from the base LiteLLM Docker image into a specialized `litellm-newrelic` image that layers on top of the base image. This approach:
- **Reduces base image size** by ~5-10 MB for users who don't need New Relic
- **Simplifies deployment** - image choice determines behavior, no environment variables needed
- **Follows Docker best practices** - specialized variants extend base image with their own configs
- **Complete isolation** - newrelic image has its own `supervisord_newrelic.conf` and entrypoint
- **Enables future observability variants** - same pattern can be used for DataDog, Prometheus, etc.

### Important Context
**No Backward Compatibility Needed:** The `USE_NEWRELIC` environment variable approach was prototyped in an unmerged PR but never released. This plan removes that approach entirely and implements clean separation from the start. Base image files (`prod_entrypoint.sh`, `supervisord.conf`) will be reverted to remove any `USE_NEWRELIC` references.

---

## Architecture Pattern

**Current State:**
- Base `litellm` image includes New Relic agent (via `requirements.txt` line 39)
- All users pull the New Relic dependency even if they don't use it

**Target State:**
- Base `litellm` image excludes New Relic agent
- New `litellm-newrelic` image extends base image and adds New Relic agent
- Users choose which image to use based on their monitoring needs

**Image Naming Convention:**
- Image name `litellm-newrelic` follows existing LiteLLM patterns for specialized variants:
  - `litellm-database` - includes database migration tools
  - `litellm-non_root` - runs as non-root user
  - `litellm-spend_logs` - spend logging features
- This approach (separate image names vs. tag suffixes like `main-stable-newrelic`) was chosen because:
  - Maintains consistency with established variant images
  - Enables independent metadata, security scanning, and pull statistics
  - Scales better for future combinations (e.g., `litellm-newrelic-database`)
  - Follows Docker conventions for feature-additive variants

---

## Implementation Steps

### 1. **Remove New Relic from Base Image**

**File:** `requirements.txt`
- **Action:** Remove line 39: `newrelic>=11.2.0,<13  # for New Relic APM and AI monitoring`
- **Impact:** Reduces base image size by ~5-10 MB
- **Risk:** Low - users who need New Relic will use the specialized image

### 2. **Create New Relic Supervisor Configuration**

**File:** `docker/supervisord_newrelic.conf` (new file)

**Purpose:** Dedicated supervisor config that always wraps the main process with `newrelic-admin`. Based on `supervisord.conf` but with New Relic hard-coded.

```ini
# ⚠️ KEEP IN SYNC: Changes to docker/supervisord.conf should be replicated here
# This config is identical to supervisord.conf except the main program command
# always wraps with newrelic-admin (no conditionals)

[supervisord]
nodaemon=true
loglevel=info
logfile=/tmp/supervisord.log
pidfile=/tmp/supervisord.pid

[group:litellm]
programs=main,health

[program:main]
command=sh -c 'exec newrelic-admin run-program python -m litellm.proxy.proxy_cli --host 0.0.0.0 --port=4000 $LITELLM_ARGS'
autostart=true
autorestart=true
startretries=3
priority=1
exitcodes=0
stopasgroup=true
killasgroup=true
stopwaitsecs=%(ENV_SUPERVISORD_STOPWAITSECS)s
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes = 0
stderr_logfile_maxbytes = 0
environment=PYTHONUNBUFFERED=true

[program:health]
command=sh -c '[ "$SEPARATE_HEALTH_APP" = "1" ] && exec uvicorn litellm.proxy.health_endpoints.health_app_factory:build_health_app --factory --host 0.0.0.0 --port=${SEPARATE_HEALTH_PORT:-4001} || exit 0'
autostart=true
autorestart=true
startretries=3
priority=2
exitcodes=0
stopasgroup=true
killasgroup=true
stopwaitsecs=%(ENV_SUPERVISORD_STOPWAITSECS)s
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes = 0
stderr_logfile_maxbytes = 0
environment=PYTHONUNBUFFERED=true

[eventlistener:process_monitor]
command=python -c "from supervisor import childutils; import os, signal; [os.kill(os.getppid(), signal.SIGTERM) for h,p in iter(lambda: childutils.listener.wait(), None) if h['eventname'] in ['PROCESS_STATE_FATAL', 'PROCESS_STATE_EXITED'] and dict([x.split(':') for x in p.split(' ')])['processname'] in ['main', 'health'] or childutils.listener.ok()]"
events=PROCESS_STATE_EXITED,PROCESS_STATE_FATAL
autostart=true
autorestart=true
```

**Key Design Decisions:**
- ✅ **No conditionals:** Main program always wraps with `newrelic-admin`, no `if/elif/else` logic
- ✅ **Self-contained:** Config file determines behavior, not environment variables
- ✅ **Clean separation:** Base image uses `supervisord.conf`, newrelic image uses `supervisord_newrelic.conf`

**⚠️ Maintenance Consideration:**
- Having two separate supervisor configs creates a maintenance burden
- Changes to `docker/supervisord.conf` (e.g., timeout adjustments, new programs, health check logic) must be manually replicated to `docker/supervisord_newrelic.conf`
- Risk of drift: The two files could diverge over time, leading to behavioral differences between base and newrelic images
- **Mitigation strategies:**
  - Document in PR template: "If modifying supervisord.conf, check if supervisord_newrelic.conf needs the same change"
  - Add a CI check that compares the two files and warns if they differ (excluding the command line)
  - Consider using a templating approach in the future if more variants are added (e.g., `supervisord_datadog.conf`)

### 3. **Create New Relic Entrypoint Script**

**File:** `docker/newrelic_entrypoint.sh` (new file)

**Purpose:** Dedicated entrypoint that routes to the New Relic-specific supervisor config or wraps directly with `newrelic-admin`.

```bash
#!/bin/sh
# ⚠️ KEEP IN SYNC: Changes to docker/prod_entrypoint.sh logic should be reviewed
# This entrypoint is based on prod_entrypoint.sh but simplified for New Relic only

if [ "$SEPARATE_HEALTH_APP" = "1" ]; then
    export LITELLM_ARGS="$@"
    export SUPERVISORD_STOPWAITSECS="${SUPERVISORD_STOPWAITSECS:-3600}"
    # Use New Relic-specific supervisor config
    exec supervisord -c /etc/supervisord_newrelic.conf
fi

# For standard mode, wrap directly with newrelic-admin
exec newrelic-admin run-program litellm "$@"
```

**Key Design Decisions:**
- ✅ **Image choice = behavior:** Using `litellm-newrelic` image means New Relic is always enabled
- ✅ **No environment variables needed:** Behavior determined by image choice alone
- ✅ **Supervisor support:** Uses dedicated `supervisord_newrelic.conf` when `SEPARATE_HEALTH_APP=1`
- ✅ **Complete isolation:** No dependency on base image's conditional logic

**⚠️ Maintenance Consideration:**
- Having a separate entrypoint creates maintenance burden similar to the supervisor config
- Changes to `docker/prod_entrypoint.sh` (e.g., new deployment modes, environment variable handling, argument processing) may need to be reviewed for applicability to `newrelic_entrypoint.sh`
- **Key difference:** The logic is simpler here (no DataDog conditionals), so drift is less likely than with supervisor configs
- **Mitigation:** Add header comment in both files, document in PR template

### 4. **Create Dockerfile.newrelic**

**File:** `docker/Dockerfile.newrelic` (new file)

**Structure:**
```dockerfile
# Multi-stage approach with published base image
ARG BASE_TAG=latest
FROM litellm/litellm:${BASE_TAG}

USER root

# Install New Relic agent
RUN pip install --no-cache-dir 'newrelic>=11.2.0,<13'

# Copy New Relic-specific configuration files
# Note: Files are in docker/ directory (flat structure, not docker/newrelic/)
COPY docker/supervisord_newrelic.conf /etc/supervisord_newrelic.conf
COPY docker/newrelic_entrypoint.sh /app/docker/newrelic_entrypoint.sh
RUN chmod +x /app/docker/newrelic_entrypoint.sh

# Override entrypoint to always use newrelic-admin
ENTRYPOINT ["/app/docker/newrelic_entrypoint.sh"]

# Metadata
LABEL org.opencontainers.image.description="LiteLLM with New Relic APM and AI monitoring"
LABEL org.opencontainers.image.documentation="https://docs.litellm.ai/docs/proxy/observability/new_relic"
```

**Key Design Decisions:**
- ✅ **Use published base image:** `FROM litellm/litellm:${BASE_TAG}` ensures we build on top of the published image
- ✅ **Dedicated configs:** Brings its own `supervisord_newrelic.conf` and `newrelic_entrypoint.sh`
- ✅ **Flat file structure:** Files in `docker/` directory to match existing variant pattern (see "File Organization" section)
- ✅ **No environment variables:** Behavior is hard-coded in the configuration files
- ✅ **Simple pip install:** Just install the New Relic package and add config files
- ✅ **Inherit everything else:** Exposed ports, working directory, CMD, etc. all come from base image
- ✅ **Simpler UX:** Users don't need to set `USE_NEWRELIC=true`

### 5. **Update GitHub Actions Workflow**

**File:** `.github/workflows/ghcr_deploy.yml`

**Changes Required:**

#### A. Add Docker Hub Job for litellm-newrelic

Add after the `docker-hub-deploy` job (around line 77):

```yaml
- name: Build and push litellm-newrelic image
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    file: ./docker/Dockerfile.newrelic
    build-args: |
      BASE_TAG=${{ github.event.inputs.tag || 'latest' }}
    tags: litellm/litellm-newrelic:${{ github.event.inputs.tag || 'latest' }}
```

#### B. Add GHCR Job for litellm-newrelic

Add a new job after `build-and-push-image-spend-logs` (around line 300):

```yaml
build-and-push-image-newrelic:
  runs-on: ubuntu-latest
  needs: [build-and-push-image]  # Must wait for base image to be built
  permissions:
    contents: read
    packages: write
  steps:
    - name: Checkout repository
      uses: actions/checkout@v4
      with:
        ref: ${{ github.event.inputs.commit_hash }}

    - name: Log in to the Container registry
      uses: docker/login-action@65b78e6e13532edd9afa3aa52ac7964289d1a9c1
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata (tags, labels) for newrelic Dockerfile
      id: meta-newrelic
      uses: docker/metadata-action@9ec57ed1fcdbf14dcef7dfbe97b2010124a938b7
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}-newrelic

    # Configure multi platform Docker builds
    - name: Set up QEMU
      uses: docker/setup-qemu-action@e0e4588fad221d38ee467c0bffd91115366dc0c5

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@edfb0fe6204400c56fbfd3feba3fe9ad1adfa345

    - name: Build and push NewRelic Docker image
      uses: docker/build-push-action@f2a1d5e99d037542a71f64918e516c093c6f3fc4
      with:
        context: .
        file: ./docker/Dockerfile.newrelic
        push: true
        build-args: |
          BASE_TAG=${{ github.event.inputs.tag || 'latest' }}
        tags: |
          ${{ steps.meta-newrelic.outputs.tags }}-${{ github.event.inputs.tag || 'latest' }},
          ${{ steps.meta-newrelic.outputs.tags }}-${{ github.event.inputs.release_type }}
          ${{ (github.event.inputs.release_type == 'stable'  || github.event.inputs.release_type == 'rc') && format('{0}/berriai/litellm-newrelic:main-{1}', env.REGISTRY, github.event.inputs.tag) || '' }},
          ${{ github.event.inputs.release_type == 'stable' && format('{0}/berriai/litellm-newrelic:main-stable', env.REGISTRY) || '' }}
        labels: ${{ steps.meta-newrelic.outputs.labels }}
        platforms: local,linux/amd64,linux/arm64,linux/arm64/v8
```

**Critical Implementation Note:**
- ✅ **Dependency ordering:** `needs: [build-and-push-image]` ensures the base image is built and pushed to Docker Hub/GHCR before building the newrelic variant
- ✅ **Build args:** Pass `BASE_TAG` to reference the correct version of the base image
- ✅ **Same tagging pattern:** Follows the existing pattern for other image variants

### 6. **Update Documentation**

**File to Update:**
- `docs/my-website/docs/observability/newrelic.md` - New Relic specific documentation page

**Documentation Changes Required:**

The current documentation describes the `USE_NEWRELIC=true` approach (lines 14-42). This needs to be completely rewritten to describe the new image-based approach:

**Replace "Enable New Relic Python Agent instrumentation" section with:**
```markdown
## Use the litellm-newrelic Docker Image

The LiteLLM proxy is available in a specialized Docker image variant with built-in New Relic monitoring: `litellm-newrelic`.

This image automatically wraps the LiteLLM process with the New Relic Python Agent - no additional configuration is needed.

**Docker Deployment:**
```bash
docker run \
  -e NEW_RELIC_LICENSE_KEY=your_key \
  -e NEW_RELIC_APP_NAME=litellm-proxy \
  litellm/litellm-newrelic:latest \
  --config /path/to/config.yaml
```

**Key Points:**
- Use `litellm-newrelic` image instead of `litellm` base image
- No `USE_NEWRELIC` environment variable needed
- Works with both standard and supervisor modes (`SEPARATE_HEALTH_APP=1`)
```

**Update "Required environment variables" section:**
- Remove references to `USE_NEWRELIC=true`
- Clarify that only `NEW_RELIC_LICENSE_KEY` and `NEW_RELIC_APP_NAME` are required
- Keep the "Enable New Relic LiteLLM Extension" section unchanged (callbacks configuration)

### 7. **Testing Strategy**

#### Local Testing Before PR:
```bash
# 1. Build base image locally
docker build -t litellm/litellm:test .

# 2. Build newrelic image locally
docker build -t litellm/litellm-newrelic:test \
  -f docker/Dockerfile.newrelic \
  --build-arg BASE_TAG=test .

# 3. Test newrelic image (USE_NEWRELIC no longer needed!)
docker run \
  -e NEW_RELIC_LICENSE_KEY=$NR_LICENSE_KEY \
  -e NEW_RELIC_APP_NAME=litellm-test \
  litellm/litellm-newrelic:test --config /app/config.yaml

# 4. Verify that base image no longer has newrelic package
docker run --rm litellm/litellm:test python -c "import newrelic" 2>&1 | grep -q "No module named" && echo "✓ Base image correctly excludes newrelic"

# 5. Verify that newrelic image has the package
docker run --rm litellm/litellm-newrelic:test python -c "import newrelic; print('✓ New Relic agent installed')"
```

#### Verification Checklist:
- [ ] Base image builds without newrelic package
- [ ] Base image size is reduced (compare with `docker images`)
- [ ] Base files have no USE_NEWRELIC references (check `prod_entrypoint.sh`, `supervisord.conf`)
- [ ] Newrelic image builds successfully from base image
- [ ] Newrelic image can import `newrelic` module
- [ ] `newrelic-admin` command is available in newrelic image
- [ ] NewRelicLogger initialization succeeds
- [ ] Custom events are recorded in New Relic UI
- [ ] Standard mode works: Process wrapped with `newrelic-admin`
- [ ] Supervisor mode works: Main process wrapped when `SEPARATE_HEALTH_APP=1`
- [ ] Config files are in sync (except command differences)

#### CI/CD Testing:
- GitHub Actions will automatically build both images on merge
- Test the published images from GHCR/Docker Hub after first release

---

## File Changes Summary

### Files to Modify:
1. `requirements.txt` - Remove line 39 (newrelic dependency)
2. `docker/prod_entrypoint.sh` - Revert to main branch (remove `USE_NEWRELIC` conditional added in PR)
3. `docker/supervisord.conf` - Revert to main branch (remove `USE_NEWRELIC` conditional added in PR)
4. `.github/workflows/ghcr_deploy.yml` - Add newrelic image build jobs

### Files to Create:
**Note:** Files use flat structure in `docker/` directory to match existing variant pattern (see "File Organization" section for rationale).

1. `docker/supervisord_newrelic.conf` - Dedicated supervisor config that hard-codes New Relic wrapping
   - **Must be kept in sync with** `docker/supervisord.conf` (except command lines)
   - Add header comment: `# ⚠️ KEEP IN SYNC: Changes to supervisord.conf should be replicated here`
2. `docker/newrelic_entrypoint.sh` - Dedicated entrypoint script that routes to newrelic supervisor config
   - **Should track changes to** `docker/prod_entrypoint.sh` logic (except APM-specific conditionals)
   - Add header comment: `# ⚠️ KEEP IN SYNC: Changes to prod_entrypoint.sh logic should be reviewed`
3. `docker/Dockerfile.newrelic` - New layered Dockerfile that extends base image
   - Follows existing convention: `Dockerfile.<variant>` (e.g., `Dockerfile.database`, `Dockerfile.non_root`)

### Files to Update (Documentation):
1. `docs/my-website/docs/observability/newrelic.md` - Rewrite to describe image-based approach instead of `USE_NEWRELIC=true`

### Files NOT to Change:
1. `litellm/integrations/newrelic/` - Integration code remains unchanged (still used by newrelic image)

**Important Notes:**
- There is **no backward compatibility concern** - the `USE_NEWRELIC` feature was never released (still in PR)
- Base image files should be clean of New Relic references - users who want New Relic use the `-newrelic` image
- The `-newrelic` image will have its own dedicated configs that don't rely on environment variables
- ⚠️ **Maintenance Warning - Supervisor Config:** Changes to `docker/supervisord.conf` (e.g., new programs, timeout adjustments, health check improvements) must be manually replicated to `docker/supervisord_newrelic.conf`.
- ⚠️ **Maintenance Warning - Entrypoint:** Changes to `docker/prod_entrypoint.sh` (e.g., new deployment modes, argument handling) should be reviewed for applicability to `docker/newrelic_entrypoint.sh`.
- See "Trade-offs and Design Decisions" section for full analysis and mitigation strategies.

---

## Recommended Build Order

Since `USE_NEWRELIC` was never released (still in PR), we can implement everything in a **single PR**:

### Single PR Implementation:

1. **Remove New Relic from base image:**
   - Remove `newrelic>=11.2.0,<13` from `requirements.txt`
   - Revert `docker/prod_entrypoint.sh` to main branch (remove `USE_NEWRELIC` conditional)
   - Revert `docker/supervisord.conf` to main branch (remove `USE_NEWRELIC` conditional)

2. **Create New Relic variant image:**
   - Add `docker/supervisord_newrelic.conf` with hard-coded New Relic wrapping
   - Add `docker/newrelic_entrypoint.sh` that routes to newrelic supervisor config
   - Add `docker/Dockerfile.newrelic` that builds on top of base image
   - Add header comments to base files: "⚠️ KEEP IN SYNC with supervisord_newrelic.conf"

3. **Update CI/CD:**
   - Add GitHub Actions jobs for building/publishing `litellm-newrelic` image
   - Ensure `needs: [build-and-push-image]` dependency so base builds first

4. **Update documentation:**
   - Rewrite `docs/my-website/docs/observability/newrelic.md` to describe image-based approach
   - Remove references to `USE_NEWRELIC=true` environment variable
   - Add release notes explaining the new image variant:
     ```markdown
     ## New Feature: New Relic Monitoring Image

     A new Docker image variant with built-in New Relic monitoring is now available: `litellm-newrelic`.

     **Usage:**
     ```bash
     docker run \
       -e NEW_RELIC_LICENSE_KEY=your_key \
       -e NEW_RELIC_APP_NAME=your_app \
       litellm/litellm-newrelic:latest
     ```

     **Key Features:**
     - Automatically wraps LiteLLM with `newrelic-admin` - no configuration flags needed
     - Includes New Relic Python agent (not in base image)
     - Same functionality as base image, with integrated monitoring
     - Supports both standard and supervisor modes

     **Why use this image?**
     - You want New Relic APM and AI monitoring for your LiteLLM deployment
     - Simpler setup - just choose the right image and set your credentials
     - Base image stays lean for users who don't need observability tools
     ```

**Result:**
- Base image is ~5-10 MB smaller (no newrelic package)
- New `litellm-newrelic` image available for users who need monitoring
- Clean implementation with no backward compatibility baggage

**Rationale:** No two-step migration needed since `USE_NEWRELIC` feature was never released. Can proceed with clean separation immediately.

---

## Alternative Approach (Not Recommended)

**Build-time variant using requirements-newrelic.txt:**
- Create `requirements-newrelic.txt` that includes base + newrelic
- Modify Dockerfile to accept a build arg for requirements file
- More complex, harder to maintain
- Doesn't follow existing patterns (database, non_root, etc.)

**Why the FROM approach is better:**
- ✅ Simpler - just install one package on top of base
- ✅ Follows Docker best practices for image layering
- ✅ Easier to maintain - single source of truth for base image
- ✅ Reuses existing published images
- ✅ Consistent with how other specialized images could be built (DataDog, Prometheus, etc.)

---

## Trade-offs and Design Decisions

### ✅ Benefits of Separate Configs (supervisord_newrelic.conf + newrelic_entrypoint.sh)
- No runtime conditionals - config files determine behavior
- Complete isolation from base image logic
- Easier to reason about - each image has its own configs
- No dependency on environment variables (no `USE_NEWRELIC=true` needed)
- Simpler logic - newrelic configs don't need to handle DataDog cases

### ⚠️ Trade-offs of Separate Configs
**supervisord_newrelic.conf:**
- **Maintenance burden:** Two supervisor configs must be kept in sync
- **Drift risk:** Config files can diverge over time if changes aren't replicated
- **Testing overhead:** Both configs need to be tested independently
- **High impact if out of sync:** Could miss critical bug fixes or feature improvements

**newrelic_entrypoint.sh:**
- **Maintenance burden:** Two entrypoint scripts must be reviewed together
- **Drift risk:** Logic changes (e.g., new deployment modes) may need replication
- **Lower impact:** Entrypoint logic is simpler (no conditionals), so less likely to drift
- **Testing overhead:** Both entrypoints need testing

### Mitigation Plan
1. **Documentation:**
   - Add header comments to all files:
     - `docker/supervisord.conf`: "⚠️ Changes here may need to be replicated to supervisord_newrelic.conf"
     - `docker/supervisord_newrelic.conf`: "⚠️ KEEP IN SYNC with supervisord.conf"
     - `docker/prod_entrypoint.sh`: "⚠️ Changes here should be reviewed for newrelic_entrypoint.sh"
     - `docker/newrelic_entrypoint.sh`: "⚠️ KEEP IN SYNC with prod_entrypoint.sh logic"
   - Update PR template to remind contributors

2. **Optional CI Check (Future Enhancement):**
   ```yaml
   # .github/workflows/check_config_drift.yml
   - name: Check supervisor config drift
     run: |
       # Compare supervisord configs (exclude command differences)
       diff -u \
         <(grep -v "newrelic-admin" docker/supervisord.conf | grep -v "USE_DDTRACE" | grep -v "ddtrace-run") \
         <(grep -v "newrelic-admin" docker/supervisord_newrelic.conf) \
         || echo "⚠️ Warning: Supervisor configs may have drifted"

   - name: Check entrypoint logic drift
     run: |
       # Compare entrypoint scripts (exclude APM-specific lines)
       diff -u \
         <(grep -v "USE_DDTRACE\|ddtrace-run\|newrelic-admin" docker/prod_entrypoint.sh) \
         <(grep -v "newrelic-admin\|supervisord_newrelic" docker/newrelic_entrypoint.sh) \
         || echo "⚠️ Warning: Entrypoint scripts may have drifted"
   ```

3. **Future Consideration:**
   - If 3+ observability variants are added, consider templating approach
   - Example: `supervisord.conf.j2` and `entrypoint.sh.j2` templates with Jinja2/envsubst to generate variants at build time
   - Or use a shared base script with variant-specific includes

### Alternative Considered: Single Config Files with Conditionals
**supervisord.conf with USE_NEWRELIC conditionals:**
- **Rejected because:** Would require `USE_NEWRELIC` environment variable, defeating the goal of "image choice = behavior"
- **Rejected because:** Adds complexity to the base image that most users don't need
- **Note:** `USE_NEWRELIC` support was prototyped in a PR but never released, so this approach is being avoided from the start

**prod_entrypoint.sh with USE_NEWRELIC:**
- **Was prototyped in PR** but being removed in favor of clean separation
- **Not used by newrelic image** - newrelic image has its own dedicated entrypoint
- Base image files will be reverted to remove any USE_NEWRELIC references

---

## File Organization: Should Files Go in docker/newrelic/ Subdirectory?

### Option 1: Flat Structure (Current Plan)
```
docker/
├── Dockerfile.newrelic
├── supervisord_newrelic.conf
├── newrelic_entrypoint.sh
├── supervisord.conf
├── prod_entrypoint.sh
├── Dockerfile.database
├── Dockerfile.non_root
└── ...
```

**Pros:**
- ✅ **Consistent with existing pattern:** All variant Dockerfiles use `Dockerfile.<variant>` naming in docker/
- ✅ **Simple paths:** No nested directories to navigate
- ✅ **GitHub Actions:** Simpler file paths in workflow (`file: ./docker/Dockerfile.newrelic`)
- ✅ **Familiar:** Matches how database, non_root, etc. variants are organized

**Cons:**
- ❌ **Related files scattered:** Entrypoint and config are separate from Dockerfile
- ❌ **No visual grouping:** Not immediately obvious which files belong to which variant
- ❌ **Flat namespace:** Could get cluttered with many variants (datadog, otel, prometheus, etc.)

---

### Option 2: Subdirectory per Variant
```
docker/
├── newrelic/
│   ├── Dockerfile
│   ├── supervisord.conf
│   └── entrypoint.sh
├── database/
│   └── Dockerfile
├── supervisord.conf
├── prod_entrypoint.sh
└── ...
```

**Pros:**
- ✅ **Clear organization:** All New Relic files in one place
- ✅ **Easy discovery:** `ls docker/newrelic/` shows everything needed for that variant
- ✅ **Scales better:** With 5+ variants, subdirectories prevent clutter
- ✅ **Namespace isolation:** Can use simple names within directory (Dockerfile, entrypoint.sh)
- ✅ **Documentation:** Each variant can have its own README in the directory
- ✅ **Future-friendly:** Pattern works well for complex variants with multiple files

**Cons:**
- ❌ **Breaking from current pattern:** Would require migrating existing variants or being inconsistent
- ❌ **Docker build context paths:** `COPY docker/newrelic/entrypoint.sh` vs `COPY docker/newrelic_entrypoint.sh`
- ❌ **GitHub Actions changes:** `file: ./docker/newrelic/Dockerfile` (minor difference)
- ❌ **Migration effort:** Would ideally move database, non_root to subdirectories for consistency

---

### Option 3: Hybrid Approach (Recommended)
```
docker/
├── newrelic/
│   ├── supervisord.conf
│   └── entrypoint.sh
├── Dockerfile.newrelic
├── supervisord.conf
├── prod_entrypoint.sh
├── Dockerfile.database
└── ...
```

**Pros:**
- ✅ **Best of both:** Dockerfiles stay in expected location, configs are grouped
- ✅ **Backward compatible:** Doesn't break existing patterns
- ✅ **Clear isolation:** Runtime configs are visibly grouped by variant
- ✅ **No migration needed:** Existing variants stay as-is
- ✅ **Incremental:** New variants can adopt this pattern

**Cons:**
- ❌ **Partially grouped:** Dockerfile still separate from configs
- ❌ **Two patterns:** Dockerfile uses suffix, configs use subdirectory

---

### Recommendation: **Start with Option 1 (Flat), Consider Option 3 for Future**

**Rationale:**
1. **Consistency first:** Match existing pattern (`Dockerfile.database`, `Dockerfile.non_root`)
2. **Low risk:** Proven approach, no workflow changes needed
3. **Easy migration:** Can move to Option 3 later if LiteLLM adds 3+ observability variants
4. **Not urgent:** With only 2-3 files for New Relic, subdirectory overhead isn't justified yet

**Future Trigger for Subdirectories:**
If LiteLLM adds `Dockerfile.datadog`, `Dockerfile.otel`, `Dockerfile.prometheus`, etc., consider:
1. Create `docker/variants/` or `docker/observability/` parent directory
2. Move all variant configs to subdirectories
3. Keep Dockerfiles at `docker/Dockerfile.<variant>` for workflow simplicity
4. Update documentation to reflect new structure

**Implementation for Current PR:**
- Use flat structure: `docker/Dockerfile.newrelic`, `docker/supervisord_newrelic.conf`, `docker/newrelic_entrypoint.sh`
- Document this decision so future variants follow the same pattern or trigger a refactor

---

## Questions to Consider

1. **Should we add similar images for DataDog?**
   - **Future consideration:** Yes, `Dockerfile.datadog` following same pattern
   - Remove `ddtrace` from base requirements.txt
   - Create `litellm/litellm-datadog:latest`
   - **Note:** If adding multiple observability variants, revisit file organization strategy

2. **Helm chart updates needed?**
   - **Yes:** Update `deploy/charts/litellm-helm/values.yaml` to support `-newrelic` image variant
   - Add a `monitoring.newrelic.enabled` flag that switches to the newrelic image

---

## Success Criteria

- [ ] Base image builds without New Relic dependency
- [ ] Base image size is reduced by 5-10 MB
- [ ] Base image files (`prod_entrypoint.sh`, `supervisord.conf`) have no `USE_NEWRELIC` references
- [ ] `litellm-newrelic` image builds successfully using base as foundation
- [ ] GitHub Actions publishes both images to Docker Hub and GHCR
- [ ] Existing integration code (`litellm/integrations/newrelic/`) works unchanged
- [ ] Both standard mode and supervisor mode (`SEPARATE_HEALTH_APP=1`) work correctly
- [ ] New Relic monitoring is enabled automatically without any environment variables
- [ ] `supervisord_newrelic.conf` correctly wraps the main process with `newrelic-admin`
- [ ] `supervisord.conf` and `supervisord_newrelic.conf` are in sync (except for command differences)
- [ ] `prod_entrypoint.sh` and `newrelic_entrypoint.sh` have consistent core logic (except for APM handling)
- [ ] Documentation clearly explains when to use which image

---

## Summary: Why This Approach is Better

**Alternative Approach (Rejected - was prototyped but never released):**
```bash
docker run \
  -e USE_NEWRELIC=true \              # Redundant flag - user already chose the image
  -e NEW_RELIC_LICENSE_KEY=key \
  -e NEW_RELIC_APP_NAME=app \
  litellm/litellm-newrelic:latest
```

**Chosen Approach (Clean - image choice = behavior):**
```bash
docker run \
  -e NEW_RELIC_LICENSE_KEY=key \
  -e NEW_RELIC_APP_NAME=app \
  litellm/litellm-newrelic:latest     # Image choice = intent, no flag needed
```

**Key Benefits:**
- ✅ **Cleaner:** No redundant `USE_NEWRELIC=true` flag
- ✅ **Explicit:** Choosing `-newrelic` image clearly signals intent
- ✅ **Self-contained:** Image brings its own configs (`supervisord_newrelic.conf`, `newrelic_entrypoint.sh`)
- ✅ **Foolproof:** Users can't accidentally choose newrelic image and forget to set the flag
- ✅ **Follows convention:** Similar to how `litellm-database` extends base for database features

**Maintenance Trade-off:**
- ⚠️ **Two config files to maintain:** `supervisord.conf` ↔ `supervisord_newrelic.conf`
- ⚠️ **Two entrypoints to maintain:** `prod_entrypoint.sh` ↔ `newrelic_entrypoint.sh`
- ⚠️ **Drift risk:** Files can diverge over time if changes aren't replicated/reviewed
- ✅ **Mitigated by:** Header comments, PR template reminders, optional CI drift checks
- ✅ **Justified because:** Achieves "image choice = behavior" without environment variables
