<#
.SYNOPSIS
    Script d'installation et de configuration des services Windows Caisse MYK via NSSM.
.DESCRIPTION
    Installe et configure en tant que services Windows à démarrage automatique :
    1. CaisseMYK-API (FastAPI Uvicorn port 8001)
    2. CaisseMYK-PrintAgent (Agent Spooler ESC/POS port 8090)
.PARAMETER BaseDir
    Répertoire racine de l'application (défaut: C:\CaisseMYK).
.PARAMETER NssmPath
    Chemin vers l'exécutable nssm.exe (défaut: C:\CaisseMYK\tools\nssm.exe).
#>

param (
    [string]$BaseDir = "C:\CaisseMYK",
    [string]$NssmPath = "C:\CaisseMYK\tools\nssm.exe",
    [string]$PythonVenv = "C:\CaisseMYK\apps\api\.venv\Scripts\python.exe"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param ([string]$Msg)
    Write-Host "`n[+] $Msg" -ForegroundColor Cyan
}

Write-Step "Vérification des prérequis NSSM & Chemins..."
if (-not (Test-Path $NssmPath)) {
    Write-Host "NSSM introuvable à l'emplacement : $NssmPath" -ForegroundColor Yellow
    Write-Host "Veuillez télécharger NSSM (https://nssm.cc) et placer nssm.exe dans $NssmPath"
    exit 1
}

$LogDir = Join-Path $BaseDir "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# -------------------------------------------------------------
# Service 1 : CaisseMYK-API (FastAPI Backend)
# -------------------------------------------------------------
$ApiService = "CaisseMYK-API"
Write-Step "Configuration du service Windows : $ApiService"

# Arrêt et suppression préalable si existant
& $NssmPath stop $ApiService 2>$null | Out-Null
& $NssmPath remove $ApiService confirm 2>$null | Out-Null

$ApiAppDir = Join-Path $BaseDir "apps\api"
$ApiArgs = "-m uvicorn caisse.main:app --host 0.0.0.0 --port 8001 --workers 2"

& $NssmPath install $ApiService $PythonVenv $ApiArgs
& $NssmPath set $ApiService AppDirectory $ApiAppDir
& $NssmPath set $ApiService Description "API Backend POS Caisse MYK (FastAPI)"
& $NssmPath set $ApiService Start SERVICE_AUTO_START
& $NssmPath set $ApiService AppStdout (Join-Path $LogDir "api_stdout.log")
& $NssmPath set $ApiService AppStderr (Join-Path $LogDir "api_stderr.log")
& $NssmPath set $ApiService AppRotateFiles 1
& $NssmPath set $ApiService AppRotateBytes 10485760 # 10 Mo par fichier de log
& $NssmPath set $ApiService AppRestartDelay 5000   # Redémarrage après 5s si crash

# -------------------------------------------------------------
# Service 2 : CaisseMYK-PrintAgent (ESC/POS Windows Spooler Agent)
# -------------------------------------------------------------
$AgentService = "CaisseMYK-PrintAgent"
Write-Step "Configuration du service Windows : $AgentService"

& $NssmPath stop $AgentService 2>$null | Out-Null
& $NssmPath remove $AgentService confirm 2>$null | Out-Null

$AgentAppDir = Join-Path $BaseDir "apps\print-agent"
$AgentArgs = "-m uvicorn agent.main:app --host 127.0.0.1 --port 8090"

& $NssmPath install $AgentService $PythonVenv $AgentArgs
& $NssmPath set $AgentService AppDirectory $AgentAppDir
& $NssmPath set $AgentService Description "Agent d'impression locale Windows Spooler ESC/POS Caisse MYK"
& $NssmPath set $AgentService Start SERVICE_AUTO_START
& $NssmPath set $AgentService AppStdout (Join-Path $LogDir "print_agent_stdout.log")
& $NssmPath set $AgentService AppStderr (Join-Path $LogDir "print_agent_stderr.log")
& $NssmPath set $AgentService AppRotateFiles 1
& $NssmPath set $AgentService AppRotateBytes 10485760
& $NssmPath set $AgentService AppRestartDelay 3000

Write-Step "Démarrage des services Windows..."
& $NssmPath start $ApiService
& $NssmPath start $AgentService

Write-Host "`n[OK] Les services Caisse MYK ont été installés et démarrés avec succès sous Windows !" -ForegroundColor Green
