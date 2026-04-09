
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script 1/2 — Installation et configuration de l'Active Directory
    Association "Pour les vieux" — Domaine PLV.local
    Windows Server 2025

.DESCRIPTION
    Ce script :
      1. Configure le nom d'hôte et l'adresse IP statique
      2. Installe le rôle AD DS + DNS
      3. Promeut le serveur en contrôleur de domaine
      4. Crée l'arborescence complète des OUs
      5. Crée tous les groupes de sécurité par établissement
      6. Crée les dossiers partagés et applique les ACL NTFS
      7. Ajoute les imprimantes réseau

.NOTES
    Exécuter en 2 phases :
      Phase 1 : sections 1 et 2 (installation + promotion DC)  => redémarrage automatique
      Phase 2 : sections 3 à 7 (OUs, groupes, partages)       => après redémarrage
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES GLOBALES
# ─────────────────────────────────────────────────────────────────────────────
$DomainName      = "PLV.local"
$DomainNetbios   = "PLV"
$DomainDN        = "DC=PLV,DC=local"
$SafeModePass    = ConvertTo-SecureString "P@ssword2025!" -AsPlainText -Force
$DefaultMDP      = "Azerty06!"
$PartageRacine   = "D:\Partages"   # Adaptez selon votre disque

# Établissements
$Etablissements  = @("Gabres","Hermitage","Cascade","Siege")
$CodeDept        = @{ Gabres="06"; Hermitage="83"; Cascade="94"; Siege="06" }

# Groupes fonctionnels par établissement (hors Siège)
$GroupesEtab = @(
    "Administratif","Cadres","Compta","Animation","Medical","Technique"
)

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Prérequis, IP statique, nom d'hôte, installation AD DS
# ─────────────────────────────────────────────────────────────────────────────
function Phase1-InstallationAD {

    Write-Host "`n=== PHASE 1 : Configuration réseau et installation AD DS ===" -ForegroundColor Cyan

    # 1.1 — Nom d'hôte
    $hostname = "SRV-PLV-DC01"
    if ($env:COMPUTERNAME -ne $hostname) {
        Write-Host "[*] Renommage du serveur en $hostname ..."
        Rename-Computer -NewName $hostname -Force
    }

    # 1.2 — Adresse IP statique (adapter l'interface et l'IP à votre environnement)
    $ifAlias = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).Name
    Write-Host "[*] Configuration IP statique sur l'interface : $ifAlias"
    New-NetIPAddress -InterfaceAlias $ifAlias `
                     -IPAddress "192.168.1.10" `
                     -PrefixLength 24 `
                     -DefaultGateway "192.168.1.1" `
                     -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $ifAlias -ServerAddresses "127.0.0.1","192.168.1.10"

    # 1.3 — Installation des rôles Windows
    Write-Host "[*] Installation des rôles AD DS, DNS, RSAT ..."
    $roles = @(
        "AD-Domain-Services",
        "DNS",
        "RSAT-AD-Tools",
        "RSAT-DNS-Server",
        "File-Services",
        "FS-FileServer",
        "Print-Services",
        "Print-Server"
    )
    Install-WindowsFeature -Name $roles -IncludeManagementTools -IncludeAllSubFeature | Out-Null
    Write-Host "[OK] Rôles installés." -ForegroundColor Green

    # 1.4 — Promotion en contrôleur de domaine
    Write-Host "[*] Promotion en contrôleur de domaine ($DomainName) ..."
    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $DomainNetbios `
        -ForestMode "WinThreshold" `
        -DomainMode "WinThreshold" `
        -SafeModeAdministratorPassword $SafeModePass `
        -InstallDns `
        -Force `
        -NoRebootOnCompletion:$false   # redémarre automatiquement

    # Le script s'arrête ici — la suite est dans Phase2 après redémarrage
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — OUs, Groupes, Partages, Imprimantes (exécuter après redémarrage)
# ─────────────────────────────────────────────────────────────────────────────
function Phase2-ConfigurationAD {

    Write-Host "`n=== PHASE 2 : OUs, Groupes, Partages ===" -ForegroundColor Cyan

    Import-Module ActiveDirectory

    # ── 2.1 OUs PRINCIPALES PAR ÉTABLISSEMENT ──
    Write-Host "[*] Création des OUs ..."
    foreach ($etab in $Etablissements) {
        $ouEtab = "OU=$etab,$DomainDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouEtab'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $etab -Path $DomainDN -ProtectedFromAccidentalDeletion $true
        }
        # Sous-OUs : Utilisateurs, Groupes, Ordinateurs
        foreach ($sub in @("Utilisateurs","Groupes","Ordinateurs")) {
            $ouSub = "OU=$sub,$ouEtab"
            if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouSub'" -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $sub -Path $ouEtab -ProtectedFromAccidentalDeletion $true
            }
        }
    }
    Write-Host "[OK] OUs créées." -ForegroundColor Green

    # ── 2.2 GROUPES DE SÉCURITÉ ──
    Write-Host "[*] Création des groupes de sécurité ..."

    foreach ($etab in $Etablissements) {
        $dept   = $CodeDept[$etab]
        $ouGrp  = "OU=Groupes,OU=$etab,$DomainDN"

        if ($etab -eq "Siege") {
            # Groupes spécifiques Siège
            foreach ($grp in @("Cadres-Siege","Compta-Siege","Administratif-Siege")) {
                if (-not (Get-ADGroup -Filter "Name -eq '$grp'" -ErrorAction SilentlyContinue)) {
                    New-ADGroup -Name $grp `
                                -GroupScope Global `
                                -GroupCategory Security `
                                -Path $ouGrp `
                                -Description "Groupe $grp - Siège"
                }
            }
        } else {
            foreach ($grp in $GroupesEtab) {
                $nomGrp = "$grp$dept"
                if (-not (Get-ADGroup -Filter "Name -eq '$nomGrp'" -ErrorAction SilentlyContinue)) {
                    New-ADGroup -Name $nomGrp `
                                -GroupScope Global `
                                -GroupCategory Security `
                                -Path $ouGrp `
                                -Description "Groupe $grp - $etab ($dept)"
                }
            }
        }
    }
    Write-Host "[OK] Groupes créés." -ForegroundColor Green

    # ── 2.3 FINE-GRAINED PASSWORD POLICY ──
    Write-Host "[*] Configuration de la politique de mots de passe ..."
    # On s'assure que la Default Domain Policy impose la complexité
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainName `
        -MinPasswordLength 8 `
        -PasswordHistoryCount 5 `
        -ComplexityEnabled $true `
        -MaxPasswordAge (New-TimeSpan -Days 90) `
        -MinPasswordAge (New-TimeSpan -Days 1)
    Write-Host "[OK] Politique MDP configurée." -ForegroundColor Green

    # ── 2.4 DOSSIERS PARTAGÉS ET ACL ──
    Write-Host "[*] Création des dossiers partagés ..."
    if (-not (Test-Path $PartageRacine)) { New-Item -ItemType Directory -Path $PartageRacine | Out-Null }

    # Dossiers pour chaque établissement (hors Siège)
    $DossiersEtab = @("Administratif","Animation","Medical","Technique","Compta","Cadres","Bibles","Utilisateurs")
    foreach ($etab in @("Gabres","Hermitage","Cascade")) {
        $dept = $CodeDept[$etab]
        foreach ($dossier in $DossiersEtab) {
            $path = "$PartageRacine\$etab\$dossier"
            if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }

            # Partage réseau
            $shareName = "${etab}_${dossier}"
            if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $shareName -Path $path -FullAccess "Everyone" | Out-Null
            }

            # ACL NTFS selon la matrice des droits
            Set-AclDossierEtab -Path $path -Dossier $dossier -Etab $etab -Dept $dept
        }
    }

    # Dossiers Siège
    $DossiersSiege = @("Administratif","Compta")
    foreach ($dossier in $DossiersSiege) {
        $path = "$PartageRacine\Siege\$dossier"
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $shareName = "Siege_${dossier}"
        if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $shareName -Path $path -FullAccess "Everyone" | Out-Null
        }
    }
    Set-AclSiege
    Write-Host "[OK] Partages créés." -ForegroundColor Green

    # ── 2.5 IMPRIMANTES RÉSEAU ──
    Write-Host "[*] Ajout des imprimantes réseau Xerox C8200 ..."
    $imprimantes = @{
        "Xerox-Siege"      = "192.168.1.50"
        "Xerox-Gabres"     = "192.168.1.51"
        "Xerox-Hermitage"  = "192.168.1.52"
        "Xerox-Cascade"    = "192.168.1.53"
    }
    foreach ($imp in $imprimantes.GetEnumerator()) {
        Add-PrinterPort -Name "IP_$($imp.Value)" -PrinterHostAddress $imp.Value -ErrorAction SilentlyContinue
        Add-Printer -Name $imp.Key `
                    -PortName "IP_$($imp.Value)" `
                    -DriverName "Xerox Global Print Driver PCL6" `
                    -Shared `
                    -ShareName $imp.Key `
                    -ErrorAction SilentlyContinue
    }
    Write-Host "[OK] Imprimantes ajoutées." -ForegroundColor Green

    Write-Host "`n=== Phase 2 terminée. Lancez maintenant 02_Import_Utilisateurs.ps1 ===" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# FONCTIONS ACL
# ─────────────────────────────────────────────────────────────────────────────
function Set-AclDossierEtab {
    param($Path, $Dossier, $Etab, $Dept)

    # Désactive l'héritage et vide les ACE héritées
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    Set-Acl -Path $Path -AclObject $acl

    $acl = Get-Acl -Path $Path

    function Add-Rule($group, $right) {
        $identity = "$DomainNetbios\$group"
        $perm = [System.Security.AccessControl.FileSystemRights]$right
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, $perm,
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($rule)
    }

    switch ($Dossier) {
        "Medical" {
            # Médical (IDE, Méd., Sec.Méd.) : Contrôle total
            Add-Rule "Medical$Dept"    "FullControl"
            # Cadres : Contrôle total
            Add-Rule "Cadres$Dept"     "FullControl"
            # AS : Lecture seule (Read inclut ListDirectory + ReadData)
            Add-Rule "Administratif$Dept" "Read"
        }
        "Administratif" {
            # Tout le monde : Contrôle total
            foreach ($grp in $GroupesEtab) { Add-Rule "$grp$Dept" "FullControl" }
        }
        "Animation" {
            # Cadres + Animation : Contrôle total
            Add-Rule "Cadres$Dept"       "FullControl"
            Add-Rule "Animation$Dept"    "FullControl"
            # Tous les autres : Lecture seule
            foreach ($grp in @("Administratif","Medical","Compta","Technique")) {
                Add-Rule "$grp$Dept" "Read"
            }
        }
        "Technique" {
            # Cadres, Technique, Informaticien : Contrôle total
            Add-Rule "Cadres$Dept"     "FullControl"
            Add-Rule "Technique$Dept"  "FullControl"
            # Aucun accès pour les autres => on n'ajoute pas de règle Allow
        }
        "Compta" {
            # Comptables + Cadres (direction) : Accès complet
            Add-Rule "Compta$Dept"  "FullControl"
            Add-Rule "Cadres$Dept"  "FullControl"
            # Aucun accès pour les autres
        }
        "Cadres" {
            # Cadres uniquement
            Add-Rule "Cadres$Dept"  "FullControl"
        }
        "Bibles" {
            # Tous : Lecture seule
            foreach ($grp in $GroupesEtab) { Add-Rule "$grp$Dept" "Read" }
            # Direction (= Cadres) : Accès complet (écrase Read)
            Add-Rule "Cadres$Dept" "FullControl"
            # Qualiticien Siège : Accès complet
            Add-Rule "Cadres-Siege" "FullControl"
        }
        "Utilisateurs" {
            # Chaque utilisateur aura son sous-dossier créé à l'import
            # On donne uniquement les admins ici
            Add-Rule "Domain Admins" "FullControl"
        }
    }

    Set-Acl -Path $Path -AclObject $acl
}

function Set-AclSiege {
    # ACL Siège Administratif : tous contrôle total
    $path = "$PartageRacine\Siege\Administratif"
    $acl  = Get-Acl -Path $path
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$DomainNetbios\Cadres-Siege",
        "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($rule)
    $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$DomainNetbios\Compta-Siege",
        "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($rule2)
    Set-Acl -Path $path -AclObject $acl

    # ACL Siège Compta : Compta-Siege + DG (Cadres-Siege) accès total
    $path = "$PartageRacine\Siege\Compta"
    $acl  = Get-Acl -Path $path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($grp in @("Cadres-Siege","Compta-Siege")) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$DomainNetbios\$grp",
            "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $path -AclObject $acl
}

# ─────────────────────────────────────────────────────────────────────────────
# POINT D'ENTRÉE
# ─────────────────────────────────────────────────────────────────────────────
$phase = Read-Host "`nQuelle phase exécuter ? [1] Installation AD  [2] Configuration post-reboot"
if ($phase -eq "1") {
    Phase1-InstallationAD
} elseif ($phase -eq "2") {
    Phase2-ConfigurationAD
} else {
    Write-Warning "Entrez 1 ou 2."
}
