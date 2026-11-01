<#
.SYNOPSIS
    Script de sauvegarde automatique de la base de données Caisse MYK sous Windows.
.DESCRIPTION
    Sauvegarde la base de données (PostgreSQL ou SQLite locale), compresse l'archive
    et applique une politique de rétention (suppression des archives de plus de 30 jours).
.PARAMETER BackupDir
    Répertoire de destination des sauvegardes (défaut : C:\CaisseMYK\Backups).
.PARAMETER RetentionDays
    Nombre de jours de rétention des sauvegardes (défaut : 30).
#>

param (
    [string]$BackupDir = "C:\CaisseMYK\Backups",
    [int]$RetentionDays = 30,
    [string]$DbEngine = "POSTGRES", # Options: POSTGRES, SQLITE
    [string]$PgHost = "localhost",
    [int]$PgPort = 5432,
    [string]$PgDatabase = "caisse_myk",
    [string]$PgUser = "postgres",
    [string]$SqlitePath = "C:\CaisseMYK\data\caisse.db"
)

$ErrorActionPreference = "Stop"
$DateStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $BackupDir "backup_log.txt"

# 1. Création du répertoire de sauvegarde si inexistant
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

function Write-Log {
    param ([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$TimeStamp] $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

Write-Log "=== Début de la sauvegarde Caisse MYK ==="

try {
    if ($DbEngine -eq "POSTGRES") {
        $DumpFile = Join-Path $BackupDir "backup_${PgDatabase}_${DateStamp}.dump"
        Write-Log "Exécution de pg_dump vers $DumpFile..."
        
        # pg_dump en format custom binaire compressé (-Fc)
        $env:PGPASSWORD = $env:CAISSE_DB_PASSWORD
        & pg_dump -h $PgHost -p $PgPort -U $PgUser -F c -b -v -f $DumpFile $PgDatabase 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Erreur lors de l'exécution de pg_dump (Code sortie: $LASTEXITCODE)"
        }
        
        $FileInfo = Get-Item $DumpFile
        Write-Log "Sauvegarde PostgreSQL réussie. Taille: $([math]::Round($FileInfo.Length / 1MB, 2)) Mo."
    }
    elseif ($DbEngine -eq "SQLITE") {
        $SqliteBackupFile = Join-Path $BackupDir "backup_sqlite_${DateStamp}.db"
        Write-Log "Copie de la base SQLite depuis $SqlitePath..."
        
        if (-not (Test-Path $SqlitePath)) {
            throw "Fichier SQLite source introuvable : $SqlitePath"
        }
        
        # Sauvegarde atomique avec .backup si sqlite3.exe est présent, sinon copie de fichier
        if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
            & sqlite3 $SqlitePath ".backup '$SqliteBackupFile'"
        } else {
            Copy-Item -Path $SqlitePath -Destination $SqliteBackupFile -Force
        }
        
        $FileInfo = Get-Item $SqliteBackupFile
        Write-Log "Sauvegarde SQLite réussie. Taille: $([math]::Round($FileInfo.Length / 1MB, 2)) Mo."
    }

    # 2. Nettoyage des anciennes sauvegardes (Rétention)
    Write-Log "Nettoyage des sauvegardes antérieures à $RetentionDays jours..."
    $CutoffDate = (Get-Date).AddDays(-$RetentionDays)
    $OldFiles = Get-ChildItem -Path $BackupDir -File | Where-Object {
        ($_.Extension -in @(".dump", ".db", ".zip")) -and ($_.CreationTime -lt $CutoffDate)
    }

    foreach ($file in $OldFiles) {
        Write-Log "Suppression de l'ancienne archive : $($file.Name)"
        Remove-Item -Path $file.FullName -Force
    }

    Write-Log "=== Sauvegarde terminée avec succès ==="
}
catch {
    Write-Log "ERREUR CRITIQUE DE SAUVEGARDE : $_"
    exit 1
}
