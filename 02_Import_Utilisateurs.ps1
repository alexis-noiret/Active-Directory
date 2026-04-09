#Requires -RunAsAdministrator
#Requires -Module ActiveDirectory
<#
.SYNOPSIS
    Script 2/2 — Import des utilisateurs depuis CSV
    Association "Pour les vieux" — Domaine PLV.local

.PARAMETER CsvPath
    Chemin vers le fichier CSV. Defaut : .\utilisateurs_PLV.csv

.EXAMPLE
    .\02_Import_Utilisateurs.ps1
    .\02_Import_Utilisateurs.ps1 -CsvPath "C:\PLV\utilisateurs_PLV.csv"
#>

param(
    [string]$CsvPath = ".\utilisateurs_PLV.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ActiveDirectory

# =============================================================================
# CONFIGURATION
# =============================================================================
$DomainDN      = "DC=PLV,DC=local"
$DomainNetbios = "PLV"
$DomainFQDN    = "PLV.local"
$DefaultMDP    = ConvertTo-SecureString "Azerty06!" -AsPlainText -Force
$PartageRacine = "D:\Partages"
$LogFile       = ".\Import_Users_$(Get-Date -Format 'yyyyMMdd_HHmm').log"

$Etablissements = @("Gabres","Hermitage","Cascade","Siege")

$CodeDept = @{
    Gabres    = "06"
    Hermitage = "83"
    Cascade   = "94"
    Siege     = "06"
}

# =============================================================================
# CORRESPONDANCE FONCTION -> GROUPES AD
# =============================================================================
$FonctionVersGroupes = @{
    "directeur"            = @("Cadres")
    "adjdirection"         = @("Cadres")
    "medecin"              = @("Cadres","Medical")
    "cadresante"           = @("Cadres")
    "psychologue"          = @("Cadres")
    "responsabletechnique" = @("Cadres")
    "dg"                   = @("Cadres")
    "drh"                  = @("Cadres")
    "qualiticien"          = @("Cadres")
    "ide"                  = @("Medical")
    "secretairemedicale"   = @("Medical","Administratif")
    "as"                   = @("Administratif")
    "ash"                  = @("Administratif")
    "secretaireaccueil"    = @("Administratif")
    "secretaireanimation"  = @("Animation","Administratif")
    "comptable"            = @("Compta")
    "chefcomptable"        = @("Compta")
    "animation"            = @("Animation")
    "informaticien"        = @("Technique")
}

$GroupesSiege = @{
    "dg"                   = @("Cadres-Siege")
    "drh"                  = @("Cadres-Siege")
    "responsabletechnique" = @("Cadres-Siege")
    "qualiticien"          = @("Cadres-Siege")
    "chefcomptable"        = @("Compta-Siege","Cadres-Siege")
}

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "OK"    { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Remove-Accents {
    param([string]$str)
    $norm = $str.Normalize([System.Text.NormalizationForm]::FormD)
    $sb   = New-Object System.Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function Get-LoginUnique {
    param(
        [string]$Prenom,
        [string]$Nom
    )
    $pClean = (Remove-Accents $Prenom.ToLower()) -replace "[^a-z0-9]", ""
    $nClean = (Remove-Accents $Nom.ToLower())    -replace "[^a-z0-9]", ""
    $base   = "$($pClean.Substring(0,1)).$nClean"
    if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }

    $login = $base
    $i     = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$login'" -ErrorAction SilentlyContinue) {
        $login = "${base}${i}"
        $i++
    }
    return $login
}

function Get-GroupesForFonction {
    param(
        [string]$Fonction,
        [string]$Etablissement
    )
    $dept   = $CodeDept[$Etablissement]
    $fonc   = $Fonction.Trim().ToLower() -replace "[^a-z0-9]", ""
    $result = @()

    if ($Etablissement -eq "Siege") {
        if ($GroupesSiege.ContainsKey($fonc)) {
            $result = $GroupesSiege[$fonc]
        } else {
            Write-Log "Fonction Siege inconnue : '$Fonction'" "WARN"
        }
    } else {
        if ($FonctionVersGroupes.ContainsKey($fonc)) {
            foreach ($prefix in $FonctionVersGroupes[$fonc]) {
                $result += "$prefix$dept"
            }
        } else {
            Write-Log "Fonction inconnue : '$Fonction' pour '$Etablissement'" "WARN"
        }
    }
    return $result
}

function New-DossierPersonnel {
    param(
        [string]$Login,
        [string]$Etablissement
    )
    $path = "$PartageRacine\$Etablissement\Utilisateurs\$Login"
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $acl = Get-Acl -Path $path
    $acl.SetAccessRuleProtection($true, $false)

    # Proprietaire : resolu par SID pour etre langue-agnostique
    $sidUser = (Get-ADUser -Identity $Login).SID
    $ntUser  = (New-Object System.Security.Principal.SecurityIdentifier($sidUser)).Translate(
                   [System.Security.Principal.NTAccount])
    $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ntUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($ruleUser)

    # Domain Admins via SID RID-512 (langue-agnostique)
    $domSID  = (Get-ADDomain).DomainSID.Value
    $daGroup = Get-ADGroup -Filter * | Where-Object { $_.SID -eq "$domSID-512" } |
               Select-Object -First 1
    if ($daGroup) {
        $ntDA   = (New-Object System.Security.Principal.SecurityIdentifier($daGroup.SID)).Translate(
                      [System.Security.Principal.NTAccount])
        $ruleDA = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $ntDA, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($ruleDA)
    }

    Set-Acl -Path $path -AclObject $acl
    return "\\SRV-PLV-DC01\${Etablissement}_Utilisateurs\$Login"
}

# =============================================================================
# IMPORTATION PRINCIPALE
# =============================================================================
function Import-Utilisateurs {

    Write-Log "=== Demarrage import utilisateurs PLV ===" "INFO"

    if (-not (Test-Path $CsvPath)) {
        Write-Log "Fichier CSV introuvable : $CsvPath" "ERROR"
        throw "CSV manquant"
    }

    $users   = Import-Csv -Path $CsvPath -Delimiter ","
    $total   = $users.Count
    $crees   = 0
    $ignores = 0
    $erreurs = 0
    $counter = 0

    foreach ($row in $users) {
        $counter++

        $nom       = $row.Nom.Trim().ToUpper()
        $prenom    = $row.Prenom.Trim()
        $etab      = $row.Etablissement.Trim()
        $fonctions = $row.Fonction.Trim() -split "-"

        Write-Progress -Activity "Import utilisateurs ($counter/$total)" `
                       -Status "$prenom $nom -- $etab" `
                       -PercentComplete (($counter / $total) * 100)

        if ($etab -notin $Etablissements) {
            Write-Log "Etablissement inconnu '$etab' pour $prenom $nom -- ignore" "WARN"
            $ignores++
            continue
        }

        $ouPath = "OU=Utilisateurs,OU=$etab,$DomainDN"

        try {
            $login       = Get-LoginUnique -Prenom $prenom -Nom $nom
            $upn         = "$login@$DomainFQDN"
            $displayName = "$prenom $nom"

            if (Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue) {
                Write-Log "Utilisateur $upn deja existant -- ignore" "WARN"
                $ignores++
                continue
            }

            # Creation du compte AD
            New-ADUser `
                -Name                  $displayName `
                -GivenName             $prenom `
                -Surname               $nom `
                -SamAccountName        $login `
                -UserPrincipalName     $upn `
                -AccountPassword       $DefaultMDP `
                -ChangePasswordAtLogon $true `
                -Enabled               $true `
                -Path                  $ouPath `
                -Department            $etab `
                -Company               "Association Pour les vieux" `
                -HomeDrive             "U:" `
                -Description           ($fonctions -join ", ")

            Write-Log "Cree : $login ($displayName) [$etab]" "OK"

            # Dossier personnel (apres creation du compte pour resoudre le SID)
            $homePath = New-DossierPersonnel -Login $login -Etablissement $etab
            Set-ADUser -Identity $login -HomeDirectory $homePath

            # Affectation aux groupes
            $groupesAjoutes = [System.Collections.Generic.List[string]]::new()

            foreach ($fonc in $fonctions) {
                if ([string]::IsNullOrWhiteSpace($fonc)) { continue }

                $grpNames = Get-GroupesForFonction -Fonction $fonc -Etablissement $etab

                foreach ($grp in $grpNames) {
                    if ([string]::IsNullOrWhiteSpace($grp)) { continue }
                    if ($groupesAjoutes.Contains($grp)) { continue }

                    try {
                        Add-ADGroupMember -Identity $grp -Members $login
                        $groupesAjoutes.Add($grp)
                        Write-Log "  -> Groupe : $grp" "INFO"
                    } catch {
                        Write-Log "  Groupe '$grp' introuvable pour $login : $_" "WARN"
                    }
                }
            }

            $crees++

        } catch {
            Write-Log "ERREUR pour $prenom $nom : $_" "ERROR"
            $erreurs++
        }
    }

    Write-Progress -Activity "Import termine" -Completed

    Write-Log "=================================================" "INFO"
    Write-Log "RESUME DE L'IMPORT" "INFO"
    Write-Log "  Total lignes CSV   : $total"   "INFO"
    Write-Log "  Comptes crees      : $crees"   "OK"
    Write-Log "  Ignores (doublons) : $ignores" "WARN"
    Write-Log "  Erreurs            : $erreurs" "ERROR"
    Write-Log "  Log complet        : $LogFile"  "INFO"
    Write-Log "=================================================" "INFO"
}

# =============================================================================
# GENERATION DU SCRIPT GPO LECTEURS RESEAU
# =============================================================================
function Export-GPOLecteursReseau {

    Write-Log "=== Generation du script GPO lecteurs reseau ===" "INFO"

    $lignes = @(
        "# GPO Lecteurs reseau -- PLV.local",
        "# A executer depuis un DC apres avoir installe le module GroupPolicy",
        "# Les preferences Drive Maps se configurent ensuite dans GPMC :",
        "#   User Config > Preferences > Windows Settings > Drive Maps",
        "",
        "Import-Module GroupPolicy",
        "",
        '$etablissements = @{ Gabres="06"; Hermitage="83"; Cascade="94" }',
        "",
        'foreach ($etab in $etablissements.Keys) {',
        '    $dept    = $etablissements[$etab]',
        '    $gpoName = "GPO_LecteursReseau_$etab"',
        '    $gpo = New-GPO -Name $gpoName -Comment "Montage lecteurs reseau $etab" -ErrorAction SilentlyContinue',
        '    if (-not $gpo) { $gpo = Get-GPO -Name $gpoName }',
        '    New-GPLink -Name $gpoName -Target "OU=$etab,DC=PLV,DC=local" -LinkEnabled Yes -ErrorAction SilentlyContinue',
        '    Write-Host "GPO $gpoName creee."',
        '    Write-Host "  U: \\SRV-PLV-DC01\${etab}_Utilisateurs\%USERNAME%  -> tous"',
        '    Write-Host "  S: \\SRV-PLV-DC01\${etab}_Administratif            -> tous"',
        '    Write-Host "  Z: \\SRV-PLV-DC01\${etab}_Bibles                   -> tous"',
        '    Write-Host "  M: \\SRV-PLV-DC01\${etab}_Medical    (filtre Medical$dept ou Cadres$dept)"',
        '    Write-Host "  P: \\SRV-PLV-DC01\${etab}_Compta     (filtre Compta$dept ou Cadres$dept)"',
        '    Write-Host "  T: \\SRV-PLV-DC01\${etab}_Technique  (filtre Technique$dept ou Cadres$dept)"',
        '    Write-Host "  X: \\SRV-PLV-DC01\${etab}_Cadres     (filtre Cadres$dept)"',
        "}"
    )
    $lignes | Out-File -FilePath ".\GPO_LecteursReseau.ps1" -Encoding UTF8
    Write-Log "Script GPO exporte : .\GPO_LecteursReseau.ps1" "OK"
}

# =============================================================================
# POINT D'ENTREE
# =============================================================================
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|     Import Utilisateurs -- Association Pour les Vieux        |" -ForegroundColor Cyan
Write-Host "|     Domaine : PLV.local                                      |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

$choix = Read-Host "Que souhaitez-vous faire ?`n  [1] Importer les utilisateurs depuis CSV`n  [2] Generer le script GPO lecteurs reseau`n  [3] Les deux`nVotre choix"

switch ($choix) {
    "1" { Import-Utilisateurs }
    "2" { Export-GPOLecteursReseau }
    "3" { Import-Utilisateurs; Export-GPOLecteursReseau }
    default { Write-Warning "Choix invalide. Entrez 1, 2 ou 3." }
}
