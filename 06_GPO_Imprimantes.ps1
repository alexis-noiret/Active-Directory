#Requires -RunAsAdministrator
#Requires -Module GroupPolicy
#Requires -Module ActiveDirectory
<#
.SYNOPSIS
    Job 06 — Creation des GPO de deploiement des imprimantes reseau
    Association Pour les Vieux — PLV.local

.DESCRIPTION
    Cree les GPO de deploiement des imprimantes Xerox C8200 :

    Regle generale :
      - Chaque etablissement deploie SA propre imprimante pour tous ses utilisateurs
      - Le Siege deploie TOUTES les imprimantes (Xerox-Siege + les 3 etablissements)

    Imprimantes :
      Xerox-Siege      -> \\SRV-PLV-DC01\Xerox-Siege      -> Siege (tous) + Cadres-Siege
      Xerox-Gabres     -> \\SRV-PLV-DC01\Xerox-Gabres     -> Gabres (tous) + Cadres-Siege
      Xerox-Hermitage  -> \\SRV-PLV-DC01\Xerox-Hermitage  -> Hermitage (tous) + Cadres-Siege
      Xerox-Cascade    -> \\SRV-PLV-DC01\Xerox-Cascade    -> Cascade (tous) + Cadres-Siege

.NOTES
    Les imprimantes doivent etre prealablement partagees sur le DC
    (fait par le script 01_Installation_AD.ps1).
    Le driver Xerox doit etre installe sur tous les postes (via GPO ou manuellement).
#>

Import-Module GroupPolicy
Import-Module ActiveDirectory

$ErrorActionPreference = "Stop"


# CONFIGURATION

$DomainFQDN  = "PLV.local"
$DomainDN    = "DC=PLV,DC=local"
$DCName      = "SRV-PLV-DC01"
$SysvolPath  = "\\$DCName\SYSVOL\$DomainFQDN\Policies"
$DriverName  = "Xerox Global Print Driver PCL6"

# Definition des imprimantes
$Imprimantes = @{
    "Xerox-Siege"     = @{ UNC="\\$DCName\Xerox-Siege";     Driver=$DriverName }
    "Xerox-Gabres"    = @{ UNC="\\$DCName\Xerox-Gabres";    Driver=$DriverName }
    "Xerox-Hermitage" = @{ UNC="\\$DCName\Xerox-Hermitage"; Driver=$DriverName }
    "Xerox-Cascade"   = @{ UNC="\\$DCName\Xerox-Cascade";   Driver=$DriverName }
}

# Etablissements et leur imprimante locale
$Etablissements = @{
    Gabres    = @{ Dept="06"; OU="OU=Gabres,$DomainDN";    Imprimante="Xerox-Gabres" }
    Hermitage = @{ Dept="83"; OU="OU=Hermitage,$DomainDN"; Imprimante="Xerox-Hermitage" }
    Cascade   = @{ Dept="94"; OU="OU=Cascade,$DomainDN";   Imprimante="Xerox-Cascade" }
}

function Get-GroupSid($groupName) {
    try {
        return (Get-ADGroup -Identity $groupName).SID.Value
    } catch {
        Write-Warning "Groupe '$groupName' introuvable, SID non disponible."
        return ""
    }
}

# =============================================================================
# GENERATION DU XML PRINTER PREFERENCES
# =============================================================================
function New-PrinterXml {
    param(
        [string]$NomImprimante,
        [string]$UNC,
        [string]$Driver,
        [bool]$Defaut = $false,
        [string[]]$GroupSIDs = @()
    )

    $guid      = [System.Guid]::NewGuid().ToString("B").ToUpper()
    $action    = "U"  # U = Update (creer si absent, mettre a jour si present)
    $defaultStr = if ($Defaut) { "1" } else { "0" }
    $ts        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Ciblage groupes
    $filtersXml = ""
    if ($GroupSIDs -and $GroupSIDs.Count -gt 0) {
        $items = ""
        foreach ($sid in $GroupSIDs) {
            if ([string]::IsNullOrEmpty($sid)) { continue }
            $grpName = try {
                (Get-ADGroup -Filter "SID -eq '$sid'" -ErrorAction SilentlyContinue).Name
            } catch { "Groupe" }
            $items += "      <FilterGroup bool=""OR"" not=""0"" name=""$DomainFQDN\$grpName"" sid=""$sid"" userContext=""1"" primaryGroup=""0"" localGroup=""0""/>`n"
        }
        if ($items) {
            $filtersXml = "    <Filters>`n$items    </Filters>"
        }
    }

    return @"
  <SharedPrinter clsid="{9A5E9697-9095-436d-A0EE-4D128FDFBF5}" name="$NomImprimante" status="$NomImprimante" image="1" changed="$ts" uid="$guid" bypassErrors="1">
    <Properties action="$action" comment="" path="$UNC" location="" default="$defaultStr" skipLocal="0" deleteAll="0" persistent="0" userContext="1" deleteAllUsers="0"/>
$filtersXml
  </SharedPrinter>
"@
}

# =============================================================================
# CREATION GPO PAR ETABLISSEMENT (imprimante locale uniquement)
# =============================================================================
function New-GPOImprimanteEtab {
    param([string]$Etab, [hashtable]$Info)

    $gpoName  = "PLV-Imprimantes-$Etab"
    $ouPath   = $Info.OU
    $impNom   = $Info.Imprimante
    $impUNC   = $Imprimantes[$impNom].UNC
    $impDrv   = $Imprimantes[$impNom].Driver

    Write-Host "`n[*] GPO imprimante $Etab : $gpoName" -ForegroundColor Cyan

    # Creer/recuperer GPO
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "Deploiement imprimante $impNom pour $Etab"
        Write-Host "    Creee : $gpoName" -ForegroundColor Green
    }

    # Lien GPO -> OU
    $lien = Get-GPInheritance -Target $ouPath | Select-Object -ExpandProperty GpoLinks |
            Where-Object DisplayName -eq $gpoName
    if (-not $lien) {
        New-GPLink -Name $gpoName -Target $ouPath -LinkEnabled Yes | Out-Null
        Write-Host "    Liee a : $ouPath" -ForegroundColor Green
    }

    # Chemin SYSVOL
    $gpoGuid     = $gpo.Id.ToString("B").ToUpper()
    $userPrefDir = "$SysvolPath\$gpoGuid\User\Preferences\Printers"
    if (-not (Test-Path $userPrefDir)) {
        New-Item -ItemType Directory -Path $userPrefDir -Force | Out-Null
    }

    # XML : une seule imprimante, defaut = oui, pas de filtre de groupe (tous les users de l'OU)
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Printers clsid="{1F577D12-3D1B-471e-A1B7-060317597B9C}">
$(New-PrinterXml -NomImprimante $impNom -UNC $impUNC -Driver $impDrv -Defaut $true)
</Printers>
"@
    $xml | Out-File -FilePath "$userPrefDir\Printers.xml" -Encoding UTF8 -Force
    Write-Host "    Printers.xml ecrit pour $impNom (defaut)" -ForegroundColor Green
}

# =============================================================================
# GPO SIEGE : TOUTES les imprimantes
# =============================================================================
function New-GPOImprimanteSiege {
    $gpoName = "PLV-Imprimantes-Siege"
    $ouPath  = "OU=Siege,$DomainDN"

    Write-Host "`n[*] GPO imprimantes Siege (toutes les imprimantes) ..." -ForegroundColor Cyan

    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "Deploiement toutes imprimantes — Siege PLV"
        Write-Host "    Creee : $gpoName" -ForegroundColor Green
    }

    $lien = Get-GPInheritance -Target $ouPath | Select-Object -ExpandProperty GpoLinks |
            Where-Object DisplayName -eq $gpoName
    if (-not $lien) {
        New-GPLink -Name $gpoName -Target $ouPath -LinkEnabled Yes | Out-Null
        Write-Host "    Liee a : $ouPath" -ForegroundColor Green
    }

    $gpoGuid     = $gpo.Id.ToString("B").ToUpper()
    $userPrefDir = "$SysvolPath\$gpoGuid\User\Preferences\Printers"
    if (-not (Test-Path $userPrefDir)) {
        New-Item -ItemType Directory -Path $userPrefDir -Force | Out-Null
    }

    # Toutes les imprimantes ; Xerox-Siege est l'imprimante par defaut
    $blocks = @()
    $premier = $true
    foreach ($impNom in @("Xerox-Siege","Xerox-Gabres","Xerox-Hermitage","Xerox-Cascade")) {
        $imp     = $Imprimantes[$impNom]
        $defaut  = $premier
        $blocks += New-PrinterXml -NomImprimante $impNom -UNC $imp.UNC `
                                  -Driver $imp.Driver -Defaut $defaut
        $premier = $false
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Printers clsid="{1F577D12-3D1B-471e-A1B7-060317597B9C}">
$($blocks -join "`n")
</Printers>
"@
    $xml | Out-File -FilePath "$userPrefDir\Printers.xml" -Encoding UTF8 -Force
    Write-Host "    Printers.xml ecrit : 4 imprimantes (Xerox-Siege par defaut)" -ForegroundColor Green
}

# =============================================================================
# GPO DRIVER XEROX (deploiement du driver sur les postes)
# =============================================================================
function New-GPODriverXerox {
    $gpoName = "PLV-Driver-Xerox-C8200"
    $ouPath  = $DomainDN   # S'applique a tous les postes du domaine

    Write-Host "`n[*] GPO driver Xerox C8200 ..." -ForegroundColor Cyan

    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "Driver Xerox C8200 — tous les postes PLV"
    }

    # Lier au domaine (tous les postes)
    $lien = Get-GPInheritance -Target $ouPath | Select-Object -ExpandProperty GpoLinks |
            Where-Object DisplayName -eq $gpoName
    if (-not $lien) {
        New-GPLink -Name $gpoName -Target $ouPath -LinkEnabled Yes | Out-Null
    }

    # Note : le deploiement de driver passe par une strategie "Printer Driver Installation"
    # dans Computer Config > Policies > Windows Settings > Deployed Printers
    # ou via un script MSI. On configure le registre pour pointer vers le serveur d'impression.
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\Software\Policies\Microsoft\Windows NT\Printers\PointAndPrint" `
        -ValueName "Restricted" -Type DWord -Value 0 | Out-Null

    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\Software\Policies\Microsoft\Windows NT\Printers\PointAndPrint" `
        -ValueName "TrustedServers" -Type DWord -Value 1 | Out-Null

    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\Software\Policies\Microsoft\Windows NT\Printers\PointAndPrint" `
        -ValueName "ServerList" -Type String -Value $DCName | Out-Null

    Write-Host "    GPO Point and Print configuree -> $DCName" -ForegroundColor Green
    Write-Host "    IMPORTANT : Installer le driver Xerox manuellement sur le DC" -ForegroundColor Yellow
    Write-Host "    puis les postes le recupereront automatiquement." -ForegroundColor Yellow
}

# =============================================================================
# BILAN : Afficher la matrice de deploiement
# =============================================================================
function Show-MatriceImprimantes {
    Write-Host "`n+---------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|          MATRICE DE DEPLOIEMENT DES IMPRIMANTES              |" -ForegroundColor Cyan
    Write-Host "+------------------+------------+------------+------------------+" -ForegroundColor Cyan
    Write-Host "| Etablissement    | Imprimante | Defaut     | Qui y a acces    |" -ForegroundColor Cyan
    Write-Host "+------------------+------------+------------+------------------+" -ForegroundColor Cyan
    Write-Host "| Gabres           | Xerox-G    | Oui        | Tous (Gabres)    |" -ForegroundColor White
    Write-Host "|                  |            |            | + Siege (tous)   |" -ForegroundColor Gray
    Write-Host "| Hermitage        | Xerox-H    | Oui        | Tous (Hermitage) |" -ForegroundColor White
    Write-Host "|                  |            |            | + Siege (tous)   |" -ForegroundColor Gray
    Write-Host "| Cascade          | Xerox-C    | Oui        | Tous (Cascade)   |" -ForegroundColor White
    Write-Host "|                  |            |            | + Siege (tous)   |" -ForegroundColor Gray
    Write-Host "| Siege            | Xerox-S    | Oui        | Tous (Siege)     |" -ForegroundColor White
    Write-Host "|                  | Xerox-G    | Non        | Tous (Siege)     |" -ForegroundColor Gray
    Write-Host "|                  | Xerox-H    | Non        | Tous (Siege)     |" -ForegroundColor Gray
    Write-Host "|                  | Xerox-C    | Non        | Tous (Siege)     |" -ForegroundColor Gray
    Write-Host "+------------------+------------+------------+------------------+" -ForegroundColor Cyan
}

# =============================================================================
# POINT D'ENTREE
# =============================================================================
Write-Host "+==================================================+" -ForegroundColor Cyan
Write-Host "|  Job 06 — GPO Imprimantes — PLV.local            |" -ForegroundColor Cyan
Write-Host "+==================================================+" -ForegroundColor Cyan

Show-MatriceImprimantes

Write-Host "`nCreation des GPO en cours ..."

foreach ($etab in $Etablissements.Keys) {
    New-GPOImprimanteEtab -Etab $etab -Info $Etablissements[$etab]
}

New-GPOImprimanteSiege
New-GPODriverXerox

Write-Host "`n+==================================================+" -ForegroundColor Green
Write-Host "|  GPO imprimantes creees et liees.                |" -ForegroundColor Green
Write-Host "|  Forcer la mise a jour : gpupdate /force /boot   |" -ForegroundColor Green
Write-Host "+==================================================+" -ForegroundColor Green
