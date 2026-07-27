# =============================================================================
# Help24 — Docker stack verification (Phase 16)
# =============================================================================
# Proves the containerised backend actually works, rather than assuming it does.
#
#   pwsh -File scripts/docker-verify.ps1              # api only
#   pwsh -File scripts/docker-verify.ps1 -Full        # api + postgres + redis
#   pwsh -File scripts/docker-verify.ps1 -Full -KeepUp
#
# Exit code 0 = every check passed. Non-zero = the first failure is printed
# with the log excerpt you need to diagnose it.
# =============================================================================

[CmdletBinding()]
param(
    # Also bring up and verify PostgreSQL and Redis.
    [switch]$Full,
    # Leave the stack running afterwards (default: tear it down).
    [switch]$KeepUp
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:Failures = @()
$profileArgs = if ($Full) { @('--profile', 'db', '--profile', 'cache') } else { @() }

function Write-Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail($msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:Failures += $msg
}

# ── 0. Preconditions ─────────────────────────────────────────────────────────
Write-Step "Preconditions"

try {
    docker version --format '{{.Server.Version}}' | Out-Null
    Write-Pass "Docker daemon is reachable"
} catch {
    Write-Fail "Docker daemon unreachable - is Docker Desktop running?"
    Write-Host "`nAborting: nothing else can be checked." -ForegroundColor Red
    exit 1
}

if (Test-Path 'backend/.env') {
    Write-Pass "backend/.env exists"
} else {
    Write-Fail "backend/.env is missing - copy backend/.env.example and fill it in"
    Write-Host "`nAborting: the api service cannot start without it." -ForegroundColor Red
    exit 1
}

# ── 1. Compose file is a valid project in every profile ──────────────────────
Write-Step "Compose configuration"

foreach ($p in @(@(), @('--profile','db'), @('--profile','cache'), @('--profile','tools'), @('--profile','full'))) {
    $label = if ($p.Count) { $p -join ' ' } else { '<default>' }
    docker compose @p config --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Pass "valid: $label" } else { Write-Fail "invalid project: $label" }
}

# ── 2. Image builds ──────────────────────────────────────────────────────────
Write-Step "Building the api image"

docker compose build api
if ($LASTEXITCODE -ne 0) {
    Write-Fail "docker compose build api failed"
    Write-Host "`nAborting: cannot verify a stack that will not build." -ForegroundColor Red
    exit 1
}
Write-Pass "image built"

$size = (docker image inspect help24/backend:local --format '{{.Size}}') / 1MB
Write-Host ("  final image size: {0:N0} MB" -f $size)

# Non-root is a hard requirement, not a preference.
$imgUser = docker image inspect help24/backend:local --format '{{.Config.User}}'
if ($imgUser -eq 'node') { Write-Pass "image runs as non-root user '$imgUser'" }
else { Write-Fail "image User is '$imgUser' - expected 'node'" }

# ── 3. Stack starts and becomes healthy ──────────────────────────────────────
Write-Step "Starting the stack"

docker compose @profileArgs up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "docker compose up failed"; exit 1 }

$expected = if ($Full) { @('help24-api','help24-postgres','help24-redis') } else { @('help24-api') }

foreach ($name in $expected) {
    Write-Host "  waiting for $name to report healthy (up to 90s)..."
    $healthy = $false
    foreach ($i in 1..45) {
        $state = docker inspect --format '{{.State.Health.Status}}' $name 2>$null
        if ($state -eq 'healthy') { $healthy = $true; break }
        if ($state -eq 'unhealthy') { break }
        Start-Sleep -Seconds 2
    }
    if ($healthy) { Write-Pass "$name is healthy" }
    else {
        Write-Fail "$name never became healthy"
        Write-Host "--- last 40 log lines: $name ---" -ForegroundColor Yellow
        docker logs --tail 40 $name 2>&1 | Write-Host
    }
}

# ── 4. The API answers over the published port ───────────────────────────────
Write-Step "HTTP reachability from the host"

$apiPort = if ($env:API_PORT) { $env:API_PORT } else { '3000' }

foreach ($path in @('/health', '/')) {
    try {
        $res = Invoke-WebRequest -Uri "http://127.0.0.1:$apiPort$path" -TimeoutSec 10 -UseBasicParsing
        $body = $res.Content | ConvertFrom-Json
        if ($res.StatusCode -eq 200 -and $body.status -eq 'ok') {
            Write-Pass "GET $path -> 200, status=ok, service=$($body.service)"
        } else {
            Write-Fail "GET $path -> $($res.StatusCode) $($res.Content)"
        }
    } catch {
        Write-Fail "GET $path failed: $($_.Exception.Message)"
    }
}

# ── 5. No missing env vars / broken imports at boot ──────────────────────────
Write-Step "Startup log analysis"

$logs = docker logs help24-api 2>&1 | Out-String

if ($logs -match '\[Config\] Missing required env variable: (\w+)') {
    Write-Fail "missing env variable: $($Matches[1]) - add it to backend/.env"
} else {
    Write-Pass "no missing required env variables"
}

if ($logs -match 'FAILED TO LOAD') {
    Write-Fail "a module failed to load (routes will 404):"
    ($logs -split "`n" | Select-String 'FAILED TO LOAD') | ForEach-Object { Write-Host "    $_" }
} elseif ($logs -match 'All observability \+ dev modules confirmed active') {
    Write-Pass "all modules loaded - startup route verification passed"
} else {
    Write-Fail "startup route verification did not report success (see logs)"
}

if ($logs -match 'Cannot find module') {
    Write-Fail "broken import detected: 'Cannot find module' in the boot log"
} else {
    Write-Pass "no broken imports"
}

# ── 6. Data services ─────────────────────────────────────────────────────────
if ($Full) {
    Write-Step "PostgreSQL"
    $pg = docker compose exec -T postgres psql -U help24 -d help24 -tAc 'select 1' 2>&1
    if ($LASTEXITCODE -eq 0 -and "$pg".Trim() -eq '1') { Write-Pass "accepts SQL (select 1 -> 1)" }
    else { Write-Fail "psql query failed: $pg" }

    Write-Step "Redis"
    $redisPw = if ($env:REDIS_PASSWORD) { $env:REDIS_PASSWORD } else { 'help24_local_redis' }
    $ping = docker compose exec -T redis redis-cli --no-auth-warning -a $redisPw ping 2>&1
    if ("$ping".Trim() -eq 'PONG') { Write-Pass "responds to PING" }
    else { Write-Fail "redis PING failed: $ping" }

    Write-Step "Network isolation"
    # postgres and redis share no network - prove it rather than trust the config.
    $reach = docker compose exec -T redis sh -c 'nc -z -w2 postgres 5432 && echo REACHABLE || echo ISOLATED' 2>&1
    if ("$reach" -match 'ISOLATED') { Write-Pass "redis cannot reach postgres (segmented networks)" }
    else { Write-Fail "redis reached postgres - network segmentation is not effective: $reach" }
}

# ── 7. Teardown ──────────────────────────────────────────────────────────────
if (-not $KeepUp) {
    Write-Step "Tearing down (volumes are preserved)"
    docker compose @profileArgs down | Out-Null
    Write-Pass "stack stopped"
} else {
    Write-Step "Stack left running (-KeepUp)"
    docker compose @profileArgs ps
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Failures.Count) CHECK(S) FAILED:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
