<#
.SYNOPSIS
    Script de restauration de la base de données Caisse MYK sous Windows.
.DESCRIPTION
    Restaure une sauvegarde PostgreSQL (.dump) ou SQLite (.db) avec vérifications préalables.
.PARAMETER BackupFilePath
    Chemin complet vers le fichier d'archive à restaurer.
.PARAMETER TargetDb
    Nom de la base de données cible (défaut : caisse_myk_restore_test ou caisse_myk).
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$BackupFilePath,
    [string]$DbEngine = "POSTGRES",
    [string]$PgHost = "localhost",
    [int]$PgPort = 5432,
    [string]$TargetDb = "caisse_myk_restore_test",
    [string]$PgUser = "postgres",
    [string]$SqliteDestPath = "C:\CaisseMYK\data\caisse.db"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param ([string]$Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$TimeStamp] $Message"
}

Write-Log "=== Début de la procédure de restauration Caisse MYK ==="

if (-not (Test-Path $BackupFilePath)) {
    Write-Error "Fichier de sauvegarde introuvable : $BackupFilePath"
    exit 1
}

try {
    if ($DbEngine -eq "POSTGRES") {
        Write-Log "Restauration PostgreSQL depuis $BackupFilePath vers la base '$TargetDb'..."
        
        $env:PGPASSWORD = $env:CAISSE_DB_PASSWORD
        
        # 1. Vérification / Création de la base cible
        Write-Log "Recréation de la base de données cible '$TargetDb'..."
        & dropdb -h $PgHost -p $PgPort -U $PgUser --if-exists $TargetDb 2>&1 | Out-Null
        & createdb -h $PgHost -p $PgPort -U $PgUser $TargetDb 2>&1 | Out-Null
        
        # 2. Restauration avec pg_restore
        Write-Log "Exécution de pg_restore..."
        & pg_restore -h $PgHost -p $PgPort -U $PgUser -d $TargetDb -v --no-owner --no-privileges $BackupFilePath 2>&1 | Out-Null
        
        Write-Log "Vérification des tables restaurées..."
        $TableCount = & psql -h $PgHost -p $PgPort -U $PgUser -d $TargetDb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
        Write-Log "Nombre de tables trouvées dans $TargetDb : $($TableCount.Trim())"
        
        Write-Log "Restauration PostgreSQL réussie avec succès."
    }
    elseif ($DbEngine -eq "SQLITE") {
        Write-Log "Restauration SQLite depuis $BackupFilePath vers $SqliteDestPath..."
        
        # Création du dossier cible si besoin
        $DestDir = Split-Path -Path $SqliteDestPath -Parent
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        
        # Copie sécurisée
        Copy-Item -Path $BackupFilePath -Destination $SqliteDestPath -Force
        Write-Log "Restauration SQLite terminée. Fichier prêt à l'emplacement : $SqliteDestPath"
    }

    Write-Log "=== Procédure de restauration terminée avec succès ==="
}
catch {
    Write-Error "ERREUR LORS DE LA RESTAURATION : $_"
    exit 1
}
