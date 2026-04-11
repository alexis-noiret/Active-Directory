# 🛡️ Active Directory Automation Lab
![PowerShell](https://img.shields.io/badge/Language-PowerShell-blue)
![Active Directory](https://img.shields.io/badge/Active%20Directory-AD%20DS-forestgreen)
![Windows Server](https://img.shields.io/badge/OS-Windows%20Server-0078D6)
![Status](https://img.shields.io/badge/Project-Lab%20Project-orange)
![Cybersecurity](https://img.shields.io/badge/Focus-Cybersecurity-red)

## 📌 Présentation

Ce projet consiste en la **mise en place et l’automatisation complète d’un environnement Active Directory** dans un contexte de laboratoire (lab), avec un focus sur :

* la gestion des identités (LDAP)
* la sécurité et la structuration du SI
* l’automatisation via PowerShell
* le déploiement de stratégies GPO

🎯 Objectif : reproduire un environnement d’entreprise réaliste et administrable.

---

## 🧱 Architecture du projet

Le projet s’appuie sur une infrastructure Active Directory classique :

* 🖥️ Contrôleur de domaine (Domain Controller)
* 👥 Utilisateurs importés automatiquement
* 🗂️ Organisation en unités organisationnelles (OU)
* 🔐 Application de stratégies de sécurité via GPO

---

## ⚙️ Fonctionnalités

### 🔧 Déploiement automatisé

* Installation d’Active Directory via script PowerShell
* Configuration initiale du domaine

### 👤 Gestion des utilisateurs

* Import automatique d’utilisateurs
* Structuration logique dans l’annuaire LDAP

### 🏢 Intégration au domaine

* Jonction automatique des machines au domaine

### 🔒 Sécurisation de l’environnement

* Mise en place de règles de sécurité AD
* Bonnes pratiques de configuration

### 🧩 Gestion des GPO

* Déploiement de lecteurs réseau
* Configuration d’imprimantes
* Application centralisée des politiques

---

## 📂 Structure du projet

```
Active-Directory/
│
├── 01_Installation_AD.ps1         # Installation et configuration du domaine
├── 02_Import_Utilisateurs.ps1    # Création des utilisateurs
├── 03_Jonction_Domaine.ps1       # Ajout des machines au domaine
├── 04_Securite_AD.ps1            # Configuration sécurité
├── 05_GPO_LecteursReseau.ps1     # Déploiement lecteurs réseau
├── 06_GPO_Imprimantes.ps1        # Déploiement imprimantes
└── organigramme2.png             # Schéma de l’infrastructure
```

---

## 🛠️ Technologies utilisées

* **Windows Server**
* **Active Directory (AD DS)**
* **LDAP**
* **PowerShell**
* **GPO (Group Policy Objects)**

---

## 🚀 Mise en œuvre

### Prérequis

* Machine virtuelle ou serveur Windows
* Droits administrateur
* Environnement réseau fonctionnel

### Lancement

1. Exécuter les scripts dans l’ordre :

   * `01_Installation_AD.ps1`
   * `02_Import_Utilisateurs.ps1`
   * `03_Jonction_Domaine.ps1`
   * etc.

2. Vérifier :

   * la création du domaine
   * la présence des utilisateurs
   * l’application des GPO

---

## 🔐 Bonnes pratiques intégrées

* Structuration claire des OU
* Automatisation des tâches répétitives
* Centralisation des politiques
* Séparation des rôles utilisateurs / administration

---

## 📸 Aperçu

> Ajouter ici des captures d’écran :

* console Active Directory
* GPO appliquées
* structure des utilisateurs

---

## 💡 Compétences démontrées

* Administration **Active Directory**
* Gestion des identités (IAM)
* Automatisation via **PowerShell**
* Mise en place de **GPO**
* Structuration d’un système d’information
* Approche sécurité d’un environnement Windows

---

## 👨‍💻 Auteur

**Alexis Noiret**
🎓 Étudiant en cybersécurité
🔗 GitHub : https://github.com/alexis-noiret

---

## 📈 Objectif professionnel

Ce projet s’inscrit dans une démarche de montée en compétences en **administration système et cybersécurité**, avec pour objectif une alternance en environnement professionnel.

---

## ⚠️ Disclaimer

Projet réalisé dans un environnement de laboratoire à des fins pédagogiques.
