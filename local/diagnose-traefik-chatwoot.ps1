# #region agent log
# Diagnóstico Swarm+Traefik+Chatwoot — escreve NDJSON em debug-962964.log (sessão 962964)
$ErrorActionPreference = "SilentlyContinue"
$script:logPath = Join-Path $PSScriptRoot "debug-962964.log"

function Write-DebugNdjson {
    param(
        [string]$message,
        [string]$hypothesisId,
        [object]$data = $null
    )
    $epoch = [DateTimeOffset]::new(1970, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $tsMs = [int64]([DateTimeOffset]::UtcNow - $epoch).TotalMilliseconds
    $obj = [ordered]@{
        sessionId   = "962964"
        timestamp   = $tsMs
        location    = "diagnose-traefik-chatwoot.ps1"
        message     = $message
        hypothesisId = $hypothesisId
        data        = $data
    }
    $line = $obj | ConvertTo-Json -Compress -Depth 8
    Add-Content -Path $script:logPath -Value $line -Encoding utf8
}
# #endregion

Write-DebugNdjson "diagnose_start" "A" @{ os = [Environment]::OSVersion.VersionString; pwsh = $PSVersionTable.PSVersion.ToString() }

# --- H1: labels do serviço Swarm (se deploy não aplica deploy.labels, router não existe) ---
$swarmErr = $null
docker info 2>&1 | Out-Null
$inSwarm = (docker info --format '{{.Swarm.LocalNodeState}}' 2>&1) -match "active|pending"
Write-DebugNdjson "docker_swarm_state" "A" @{ inSwarm = [bool]$inSwarm; raw = "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>&1)" }

$svcName = $null
$svcLs = docker service ls --format "{{.Name}}" 2>&1
if ($svcLs) {
    $match = $svcLs | Where-Object { $_ -match "chatwoot" }
    $svcName = if ($match) { $match | Select-Object -First 1 } else { $null }
}
Write-DebugNdjson "chatwoot_service_name" "A" @{ found = $null -ne $svcName; name = $svcName; allChatwootNames = $match }

$labelDump = $null
if ($svcName) {
    $labelDump = docker service inspect $svcName --format '{{json .Spec.Labels}}' 2>&1 | Out-String
    $hasTraefik = $labelDump -match "traefik\.enable|traefik\.http\.routers"
    Write-DebugNdjson "service_labels" "A" @{
        hasTraefikLikeLabels = [bool]$hasTraefik
        labelJsonLength      = if ($labelDump) { $labelDump.Trim().Length } else { 0 }
        # Sem imprimir a stack inteira se for enorme: só keys
    }
    try {
        $j = $labelDump | ConvertFrom-Json
        if ($j.PSObject.Properties) {
            $keys = @($j.PSObject.Properties.Name) | Where-Object { $_ -like "traefik*" } | Select-Object -First 30
            Write-DebugNdjson "traefik_label_keys" "A" @{ keys = $keys; count = $keys.Count }
            $vHttp  = $j.'traefik.http.routers.chatwoot_http.rule'
            $vHttps = $j.'traefik.http.routers.chatwoot_https.rule'
            Write-DebugNdjson "traefik_rule_values_parsed" "F" @{
                httpRule  = if ($vHttp) { [string]$vHttp } else { "MISSING" }
                httpsRule = if ($vHttps) { [string]$vHttps } else { "MISSING" }
            }
        }
    } catch { Write-DebugNdjson "label_parse_error" "A" @{ error = $_.Exception.Message } }
} else { Write-DebugNdjson "no_chatwoot_service" "A" @{ hint = "Nenhum serviço cujo nome contenha 'chatwoot' em docker service ls" } }

# --- H2: HTTP com Host (curl; evita bugs do IWR 5.1 com cabeçalho Host) ---
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
    $cxe = if ($curl.Path) { $curl.Path } else { $curl.Source }
    $c1 = [string](& $cxe -sS -o NUL -w '%{http_code}' -H 'Host: chatwoot.localhost' 'http://127.0.0.1/' 2>&1)
    $c2o = [string](& $cxe -sS -H 'Host: chatwoot.localhost' 'http://127.0.0.1/' 2>&1)
    if ($c2o.Length -gt 500) { $c2o = $c2o.Substring(0, 500) }
    Write-DebugNdjson "curl_host_chatwoot" "B" @{ statusCode = $c1; bodySample = $c2o }
} else { Write-DebugNdjson "curl_host_chatwoot" "B" @{ error = "curl.exe nao encontrado" } }

# --- H3: sem header Host (referência) ---
if ($curl) {
    $cxe2 = if ($curl.Path) { $curl.Path } else { $curl.Source }
    $c3 = [string](& $cxe2 -sS -o NUL -w '%{http_code}' 'http://127.0.0.1/' 2>&1)
    Write-DebugNdjson "curl_no_host" "C" @{ statusCode = $c3 }
} else { Write-DebugNdjson "curl_no_host" "C" @{ error = "curl.exe nao encontrado" } }

# --- H4: redes Traefik + Chatwoot (IDs/nomes) ---
$trName = (docker service ls --format "{{.Name}}" 2>&1) | Where-Object { $_ -match "traefik" } | Select-Object -First 1
Write-DebugNdjson "traefik_service" "D" @{ name = $trName }
foreach ($n in @($trName, $svcName)) {
    if (-not $n) { continue }
    $nets = docker service inspect $n --format '{{json .Spec.TaskTemplate.Networks}}' 2>&1
    Write-DebugNdjson "service_networks" "D" @{ service = $n; taskNetworksJson = ($nets | Out-String) }
}

# --- H5: portos publicados no serviço Traefik ---
if ($trName) {
    $p = docker service inspect $trName --format '{{json .Endpoint.Ports}}' 2>&1
    Write-DebugNdjson "traefik_published_ports" "E" @{ endpointPortsJson = ($p | Out-String) }
}

# --- Últimas linhas de log Traefik (se existir) — truncar p/ JSON seguro ---
if ($trName) {
    try {
        $logTail = [string](docker service logs $trName --tail 15 2>&1)
        $logTail = $logTail -replace '[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD]', '?'
        if ($logTail.Length -gt 1800) { $logTail = $logTail.Substring(0, 1800) }
        Write-DebugNdjson "traefik_logs_tail" "E" @{ tail = $logTail }
    } catch { Write-DebugNdjson "traefik_logs_error" "E" @{ err = $_.Exception.Message } }
}

# --- Traefik: confirma args em runtime (H-AO) — se faltar --entrypoints.websecure, rotas websecure nao sao criadas ---
if ($trName) {
    $argsJ = docker service inspect $trName --format '{{json .Spec.TaskTemplate.ContainerSpec.Args}}' 2>&1 | Out-String
    if ($argsJ.Length -gt 30000) { $argsJ = $argsJ.Substring(0, 30000) + "…" }
    $hasWs = $argsJ -match "websecure"
    Write-DebugNdjson "traefik_container_args" "G" @{ hasWebsecureArg = [bool]$hasWs; argsJsonPreview = $argsJ }
}

# --- F: API (timeout curto) — requer --api.insecure no Traefik em execução; redeploy 1-traefik.yaml se recusar ---
if ($trName) {
    $tcid = docker ps -q -f "name=traefik_traefik" | Select-Object -First 1
    Write-DebugNdjson "traefik_task_container" "F" @{ containerId = $tcid }
    if ($tcid) {
        $apiraw = [string](docker exec $tcid sh -c "wget -T 2 -qO- http://127.0.0.1:8080/api/http/routers 2>&1" 2>&1)
        if ($apiraw -match "routers" -or $apiraw -match "chatwoot" -or $apiraw -match "can.t connect" -or $apiraw -match "refused" -or $apiraw.Length -gt 2) {
            $apiraw2 = $apiraw -replace '[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD]', '?'
            if ($apiraw2.Length -gt 12000) { $apiraw2 = $apiraw2.Substring(0, 12000) }
            $hasCwoot = $apiraw2 -match "chatwoot"
            $n = if ($apiraw2.Length) { $apiraw2.Length } else { 0 }
            $sub = if ($n -gt 0) { $apiraw2.Substring(0, [Math]::Min(4000, $n)) } else { "" }
            Write-DebugNdjson "traefik_api_http_routers" "F" @{ hasChatwoot = [bool]$hasCwoot; bodyLen = $n; bodyPreview = $sub }
        } else {
            Write-DebugNdjson "traefik_api_http_routers_fail" "F" @{ wgetOutput = $apiraw }
        }
    }
}
Write-DebugNdjson "diagnose_end" "A" @{ ok = $true }
