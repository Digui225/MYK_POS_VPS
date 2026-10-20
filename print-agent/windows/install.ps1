#Requires -RunAsAdministrator
<#
Installe l'agent d'impression sur le poste Windows : environnement Python, puis tâche planifiée
au démarrage sous le compte SYSTEM, relancée automatiquement (même rôle qu'un service).

PowerShell en administrateur, depuis le dossier print-agent (ex. C:\CaisseMYK\print-agent) :
  powershell -ExecutionPolicy Bypass -File windows\install.ps1
  powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Uninstall

Prérequis : Python 3.12 installé « pour tous les utilisateurs » (python.org), pilote de
l'imprimante installé (l'imprimante apparaît dans Paramètres > Imprimantes).
#>
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$TaskName = "CaisseMYK-AgentImpression"
$Dir = Split-Path -Parent $PSScriptRoot

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Tâche $TaskName supprimée."
    exit 0
}

Set-Location $Dir

if (-not (Test-Path .venv)) {
    if (Get-Command py -ErrorAction SilentlyContinue) { & py -3.12 -m venv .venv }
    else { & python -m venv .venv }
    if ($LASTEXITCODE -ne 0) {
        throw "Python 3.12 introuvable : l'installer pour tous les utilisateurs (python.org)."
    }
}
& .venv\Scripts\python.exe -m pip install --quiet --disable-pip-version-check -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw "Installation des dépendances échouée (accès Internet ?)." }

if (-not (Test-Path .env)) {
    Copy-Item windows\.env.example .env
    Write-Host "-> .env créé. Imprimantes installées (valeur de PRINTER_NAME) :"
    & .venv\Scripts\python.exe -m agent --list
    Write-Host "Renseigner API_URL, TERMINAL_TOKEN et PRINTER_NAME (notepad .env), puis relancer."
    exit 1
}

$python = Join-Path $Dir ".venv\Scripts\python.exe"
$action = New-ScheduledTaskAction -Execute $python -Argument "-m agent" -WorkingDirectory $Dir
# démarrage de Windows, plus un rappel toutes les 5 min : relance l'agent s'il s'est arrêté
# (« redémarrer en cas d'échec » ne joue que si la tâche échoue à démarrer). Déjà en cours :
# le rappel est ignoré (IgnoreNew).
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue  # reprend le nouveau .env
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5
Write-Host "Agent démarré (tâche $TaskName). Dernières lignes du journal :"
if (Test-Path logs\agent.log) { Get-Content logs\agent.log -Tail 5 }
Write-Host "Suivi : Get-Content $Dir\logs\agent.log -Wait -Tail 50"
