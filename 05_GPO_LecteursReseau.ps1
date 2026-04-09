#Requires -RunAsAdministrator
#Requires -Module GroupPolicy
#Requires -Module ActiveDirectory
Import-Module GroupPolicy
Import-Module ActiveDirectory

$ErrorActionPreference = "Stop"
# CONFIGURATION
$DomainFQDN  = "PLV.local"
$DomainDN    = "DC=PLV,DC=local"
$DCName      = "SRV-PLV-DC01"
$SysvolPath  = "\\$DCName\SYSVOL\$DomainFQDN\Policies"

$Etablissements = @{
    Gabres    = @{ Dept="06"; OU="OU=Gabres,$DomainDN" }
    Hermitage = @{ Dept="83"; OU="OU=Hermitage,$DomainDN" }
    Cascade   = @{ Dept="94"; OU="OU=Cascade,$DomainDN" }
}

# Obtenir le SID d'un groupe AD
function Get-GroupSid($groupName) {
    try {
        return (Get-ADGroup -Identity $groupName).SID.Value
    } catch {
        Write-Warning "Groupe '$groupName' introuvable."
        return $null
    }
}


# GENERATION DU XML user pref

function New-DriveMapsXml {
    param(
        [string]$Etab,
        [string]$Dept,
        [string]$Server = $DCName
    )
    $drives = @()

    # Fonction interne : fabrique une balise <Drive>
    function New-DriveXml {
        param(
            [string]$Letter,      # "U","S","M"...
            [string]$Path,        # UNC du partage
            [string]$Label,       # Etiquette affichee
            [string[]]$GroupSIDs  # SIDs des groupes autorises (vide = tous)
        )
        $guid = [System.Guid]::NewGuid().ToString("B").ToUpper()

        # Ciblage : si des groupes sont fournis, on construit les filtres
        $filtersXml = ""
        if ($GroupSIDs -and $GroupSIDs.Count -gt 0) {
            $items = ""
            foreach ($sid in $GroupSIDs) {
                if (-not $sid) { continue }
                $items += @"
            <FilterGroup bool="AND" not="0" name="$DomainFQDN\$(Get-ADGroup -Filter "SID -eq '$sid'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)" sid="$sid" userContext="1" primaryGroup="0" localGroup="0"/>
"@
            }
            if ($items) {
                $filtersXml = "<Filters>$items</Filters>"
            }
        }

        return @"
    <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="$($Letter):" status="$($Letter):" image="2" changed="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" uid="$guid" bypassErrors="1">
      <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="$Path" label="$Label" persistent="1" useLetter="1" letter="$Letter"/>
      $filtersXml
    </Drive>
"@
    }

    # --- U: Dossier personnel (tous) ---
    $drives += New-DriveXml -Letter "U" `
        -Path "\\$Server\${Etab}_Utilisateurs\%USERNAME%" `
        -Label "Mon dossier ($Etab)" `
        -GroupSIDs @()

    # --- S: Administratif (tous) ---
    $drives += New-DriveXml -Letter "S" `
        -Path "\\$Server\${Etab}_Administratif" `
        -Label "Administratif ($Etab)" `
        -GroupSIDs @()

    # --- Z: Bibles (tous) ---
    $drives += New-DriveXml -Letter "Z" `
        -Path "\\$Server\${Etab}_Bibles" `
        -Label "Bibles ($Etab)" `
        -GroupSIDs @()

    # --- M: Medical (Medical + Cadres) ---
    $sidMedical = Get-GroupSid "Medical$Dept"
    $sidCadres  = Get-GroupSid "Cadres$Dept"
    $drives += New-DriveXml -Letter "M" `
        -Path "\\$Server\${Etab}_Medical" `
        -Label "Medical ($Etab)" `
        -GroupSIDs @($sidMedical, $sidCadres)

    # --- P: Compta (Compta + Cadres) ---
    $sidCompta = Get-GroupSid "Compta$Dept"
    $drives += New-DriveXml -Letter "P" `
        -Path "\\$Server\${Etab}_Compta" `
        -Label "Comptabilite ($Etab)" `
        -GroupSIDs @($sidCompta, $sidCadres)

    # --- T: Technique (Technique + Cadres) ---
    $sidTech = Get-GroupSid "Technique$Dept"
    $drives += New-DriveXml -Letter "T" `
        -Path "\\$Server\${Etab}_Technique" `
        -Label "Technique ($Etab)" `
        -GroupSIDs @($sidTech, $sidCadres)

    # --- X: Cadres uniquement ---
    $drives += New-DriveXml -Letter "X" `
        -Path "\\$Server\${Etab}_Cadres" `
        -Label "Cadres ($Etab)" `
        -GroupSIDs @($sidCadres)

    $xmlContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-8A48251F4B67}">
$($drives -join "`n")
</Drives>
"@
    return $xmlContent
}

# =============================================================================
# CREATION DES GPO PAR ETABLISSEMENT
# =============================================================================
function New-GPOLecteursReseau {
    param(
        [string]$Etab,
        [hashtable]$Info
    )

    $gpoName = "PLV-LecteursReseau-$Etab"
    $dept    = $Info.Dept
    $ouPath  = $Info.OU

    Write-Host "`n[*] Traitement GPO : $gpoName ..." -ForegroundColor Cyan

    # Creer ou recuperer la GPO
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "Lecteurs reseau utilisateurs $Etab — PLV.local"
        Write-Host "    GPO creee : $gpoName" -ForegroundColor Green
    } else {
        Write-Host "    GPO existante, mise a jour : $gpoName" -ForegroundColor Yellow
    }

    # Lier la GPO a l'OU de l'etablissement
    $lien = Get-GPInheritance -Target $ouPath | Select-Object -ExpandProperty GpoLinks |
            Where-Object DisplayName -eq $gpoName
    if (-not $lien) {
        New-GPLink -Name $gpoName -Target $ouPath -LinkEnabled Yes | Out-Null
        Write-Host "    Lien GPO -> $ouPath cree." -ForegroundColor Green
    }

    # Chemin SYSVOL de la GPO
    $gpoGuid    = $gpo.Id.ToString("B").ToUpper()
    $gpoPolicies = "$SysvolPath\$gpoGuid"
    $userPrefDir = "$gpoPolicies\User\Preferences\Drives"

    if (-not (Test-Path $userPrefDir)) {
        New-Item -ItemType Directory -Path $userPrefDir -Force | Out-Null
    }

    # Ecrire le XML des Drive Maps
    $xml = New-DriveMapsXml -Etab $Etab -Dept $dept
    $xmlPath = "$userPrefDir\Drives.xml"
    $xml | Out-File -FilePath $xmlPath -Encoding UTF8 -Force
    Write-Host "    Drive Maps XML ecrit : $xmlPath" -ForegroundColor Green

    # Activer User Preferences dans la GPO (CSE GUID Drive Maps)
    # GUID CSE: {88E729D6-BDC1-11D1-BD2A-00C04FB9603F} = User Config \ Drive Maps
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
        -ValueName "DisableLGPOProcessing" -Type DWord -Value 0 `
        -ErrorAction SilentlyContinue | Out-Null

    Write-Host "    GPO $gpoName configuree." -ForegroundColor Green
}

# =============================================================================
# GPO SPECIFIQUE SIEGE
# =============================================================================
function New-GPOSiege {
    $gpoName = "PLV-LecteursReseau-Siege"
    $ouPath  = "OU=Siege,$DomainDN"

    Write-Host "`n[*] Traitement GPO Siege ..." -ForegroundColor Cyan

    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "Lecteurs reseau Siege — PLV.local"
    }

    $lien = Get-GPInheritance -Target $ouPath | Select-Object -ExpandProperty GpoLinks |
            Where-Object DisplayName -eq $gpoName
    if (-not $lien) {
        New-GPLink -Name $gpoName -Target $ouPath -LinkEnabled Yes | Out-Null
    }

    $gpoGuid    = $gpo.Id.ToString("B").ToUpper()
    $userPrefDir = "$SysvolPath\$gpoGuid\User\Preferences\Drives"
    if (-not (Test-Path $userPrefDir)) {
        New-Item -ItemType Directory -Path $userPrefDir -Force | Out-Null
    }

    $sidCadresSiege = Get-GroupSid "Cadres-Siege"
    $sidComptaSiege = Get-GroupSid "Compta-Siege"
    $guidU = [System.Guid]::NewGuid().ToString("B").ToUpper()
    $guidS = [System.Guid]::NewGuid().ToString("B").ToUpper()
    $guidP = [System.Guid]::NewGuid().ToString("B").ToUpper()

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-8A48251F4B67}">
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="U:" status="U:" image="2" changed="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" uid="$guidU" bypassErrors="1">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\$DCName\Siege_Utilisateurs\%USERNAME%" label="Mon dossier (Siege)" persistent="1" useLetter="1" letter="U"/>
  </Drive>
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="S:" status="S:" image="2" changed="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" uid="$guidS" bypassErrors="1">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\$DCName\Siege_Administratif" label="Administratif (Siege)" persistent="1" useLetter="1" letter="S"/>
  </Drive>
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="P:" status="P:" image="2" changed="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" uid="$guidP" bypassErrors="1">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\$DCName\Siege_Compta" label="Comptabilite (Siege)" persistent="1" useLetter="1" letter="P"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$DomainFQDN\Cadres-Siege" sid="$sidCadresSiege" userContext="1" primaryGroup="0" localGroup="0"/>
    </Filters>
  </Drive>
</Drives>
"@

    $xml | Out-File -FilePath "$userPrefDir\Drives.xml" -Encoding UTF8 -Force
    Write-Host "    GPO Siege configuree." -ForegroundColor Green
}

# =============================================================================
# POINT D'ENTREE
# =============================================================================
Write-Host "+==================================================+" -ForegroundColor Cyan
Write-Host "|  Job 05 — GPO Lecteurs Reseau — PLV.local        |" -ForegroundColor Cyan
Write-Host "+==================================================+" -ForegroundColor Cyan

foreach ($etab in $Etablissements.Keys) {
    New-GPOLecteursReseau -Etab $etab -Info $Etablissements[$etab]
}
New-GPOSiege

Write-Host "`n+==================================================+" -ForegroundColor Green
Write-Host "|  GPO lecteurs reseau creees et liees.            |" -ForegroundColor Green
Write-Host "|  Forcer la mise a jour : gpupdate /force         |" -ForegroundColor Green
Write-Host "+==================================================+" -ForegroundColor Green
