#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Job 03 — Jonction des postes Windows au domaine PLV.local
    A executer sur chaque poste de travail Windows (pas sur le DC)

.DESCRIPTION
    1. Configure l'adresse IP et le DNS pointant vers le DC
    2. Renomme le poste selon la convention PLV-{ETAB}-PC{N}
    3. Joint le poste au domaine PLV.local
    4. Deplace le compte ordinateur dans l'OU Ordinateurs de l'etablissement

.NOTES
    Prerequis sur la VM poste de travail :
      - Windows 10/11 Pro ou Enterprise (pas Home — pas de jonction domaine)
      - Connexion reseau fonctionnelle vers le DC (192.168.1.10)
      - PowerShell 5.1 minimum
      - Exécuter en tant qu'Administrateur local
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("Gabres","Hermitage","Cascade","Siege")]
    [string]$Etablissement,

    [Parameter(Mandatory)]
    [int]$NumeroPoste,

    [string]$DCAdresse   = "192.168.1.10",
    [string]$Passerelle  = "192.168.1.1",
    [string]$DomaineName = "PLV.local"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# VARIABLES
# =============================================================================
$NomPoste    = "PLV-$($Etablissement.Substring(0,3).ToUpper())-PC$('{0:D2}' -f $NumeroPoste)"
$OUOrdinateurs = "OU=Ordinateurs,OU=$Etablissement,DC=PLV,DC=local"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Jonction domaine PLV.local" -ForegroundColor Cyan
Write-Host "  Poste    : $NomPoste" -ForegroundColor Cyan
Write-Host "  Etab.    : $Etablissement" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# =============================================================================
# 1. CONFIGURATION RESEAU
# =============================================================================
Write-Host "`n[1/4] Configuration reseau ..." -ForegroundColor Yellow

$adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
if (-not $adapter) { throw "Aucune interface reseau active trouvee." }

# Supprimer les adresses IP existantes pour eviter les conflits
Remove-NetIPAddress -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute     -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue

# IP dans le sous-reseau du DC (200 + NumeroPoste pour eviter les collisions)
$IPPoste = "192.168.1.$(200 + $NumeroPoste)"
New-NetIPAddress -InterfaceAlias $adapter.Name `
                 -IPAddress $IPPoste `
                 -PrefixLength 24 `
                 -DefaultGateway $Passerelle | Out-Null

# DNS : DC en primaire, secondaire public en fallback
Set-DnsClientServerAddress -InterfaceAlias $adapter.Name `
                            -ServerAddresses $DCAdresse,"8.8.8.8"

Write-Host "   IP : $IPPoste / DNS : $DCAdresse" -ForegroundColor Green

# Test de connectivite vers le DC
Write-Host "   Test de connectivite vers le DC ..."
$ping = Test-Connection -ComputerName $DCAdresse -Count 2 -Quiet
if (-not $ping) {
    throw "Impossible de joindre le DC ($DCAdresse). Verifiez le reseau."
}
Write-Host "   DC joignable." -ForegroundColor Green

# =============================================================================
# 2. RENOMMAGE DU POSTE
# =============================================================================
Write-Host "`n[2/4] Renommage du poste en '$NomPoste' ..." -ForegroundColor Yellow

if ($env:COMPUTERNAME -ne $NomPoste) {
    Rename-Computer -NewName $NomPoste -Force
    Write-Host "   Renomme. Le redemarrage sera effectue apres la jonction." -ForegroundColor Green
} else {
    Write-Host "   Poste deja nomme correctement." -ForegroundColor Green
}

# =============================================================================
# 3. JONCTION AU DOMAINE
# =============================================================================
Write-Host "`n[3/4] Jonction au domaine $DomaineName ..." -ForegroundColor Yellow

$cred = Get-Credential -Message "Identifiants d'un compte Administrateur du domaine (ex: PLV\Administrateur)"

Add-Computer -DomainName $DomaineName `
             -Credential $cred `
             -OUPath $OUOrdinateurs `
             -Force

Write-Host "   Jonction au domaine reussie." -ForegroundColor Green

# =============================================================================
# 4. CONFIGURATION POST-JONCTION (avant redemarrage)
# =============================================================================
Write-Host "`n[4/4] Configuration post-jonction ..." -ForegroundColor Yellow

# Activer le Bureau a distance (RDP) pour administration
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
                 -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Bureau a distance" -ErrorAction SilentlyContinue

# Desactiver IPv6 (recommande en environnement AD pur IPv4)
Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

# Parametres de gestion de l'alimentation : jamais en veille (poste professionnel)
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 30

Write-Host "   RDP active, IPv6 desactive, veille configuree." -ForegroundColor Green

# =============================================================================
# BILAN ET REDEMARRAGE
# =============================================================================
Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "  Configuration terminee !" -ForegroundColor Green
Write-Host "  Le poste va redemarrer dans 15 secondes." -ForegroundColor Yellow
Write-Host "  Apres redemarrage, connectez-vous avec un" -ForegroundColor Yellow
Write-Host "  compte du domaine PLV\login" -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan

Start-Sleep -Seconds 15
Restart-Computer -Force
