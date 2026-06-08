# fedora-agents MCP Server

Serveur MCP (Model Context Protocol) qui expose les agents VM-Controller et Backup-Manager
via le protocole MCP. Permet a Claude Code de gerer les VMs KVM et les backups directement.

## Architecture

```
mcp-server/
  src/
    index.ts          -- point d'entree, enregistrement des outils MCP
    config.ts         -- timeouts, permissions, codes d'erreur
    logger.ts         -- logging JSON structure
    tools/
      vm-controller.ts    -- outils vm_start, vm_stop, vm_status, vm_exec, vm_copy,
                             vm_snapshot, vm_verify, vm_clone, vm_clone_system, vm_destroy
      backup-manager.ts   -- outils backup_create, backup_list, backup_restore,
                             backup_verify, backup_clean, backup_status
      vm-portability.ts   -- outils vm_export, vm_import
    utils/
      executor.ts     -- execution des scripts bash avec retry, timeout, gestion erreurs
      validation.ts   -- schemas Zod pour tous les parametres d'outils
```

## Outils MCP exposes

### help
Liste tous les outils disponibles avec leurs descriptions.
- Script sous-jacent: aucun (genere directement dans index.ts)

### VM Controller

| Outil | Script sous-jacent | Description |
|-------|-------------------|-------------|
| `vm_start` | `vm-controller/vm-start.sh` | Demarre une VM, attend optionnellement SSH |
| `vm_stop` | `vm-controller/vm-stop.sh` | Arrete une VM (proprement ou force) |
| `vm_destroy` | `vm-controller/vm-destroy.sh` | Supprime definition + stockage d'une VM |
| `vm_status` | `vm-controller/vm-status.sh` | Affiche l'etat d'une VM (ou liste toutes) |
| `vm_exec` | `vm-controller/vm-exec.sh` | Execute une commande dans une VM via SSH |
| `vm_copy` | `vm-controller/vm-copy.sh` | Copie des fichiers hote <-> VM via SCP |
| `vm_snapshot` | `vm-controller/vm-snapshot.sh` | Gere les snapshots (create/list/restore/delete) |
| `vm_verify` | `kvm/verify-vm-clone.sh` | Verifie qu'un clone est fidele au systeme hote |
| `vm_clone` | `kvm/kvm-clone.sh` | Clone une VM existante (complet ou lie) |
| `vm_clone_system` | `kvm/kvm-clone-system.sh` | Clone le systeme hote entier vers une VM |

### Backup Manager

| Outil | Script sous-jacent | Description |
|-------|-------------------|-------------|
| `backup_status` | `backup-manager/backup-status.sh` | Dashboard global des backups |
| `backup_list` | `backup-manager/backup-list.sh` | Liste les backups disponibles |
| `backup_create` | `backup-manager/backup-create.sh` | Cree un backup (timeshift/borg/vm-snapshot/manual) |
| `backup_verify` | `backup-manager/backup-verify.sh` | Verifie l'integrite des backups |
| `backup_restore` | `backup-manager/backup-restore.sh` | Restaure un backup (destructif) |
| `backup_clean` | `backup-manager/backup-clean.sh` | Applique les politiques de retention |

### VM Portabilite

| Outil | Script sous-jacent | Description |
|-------|-------------------|-------------|
| `vm_export` | `vm-controller/vm-export.sh` | Exporte une VM en archive .tar.gz sanitarisee |
| `vm_import` | `vm-controller/vm-import.sh` | Importe une VM depuis une archive vm_export |

## Scripts helpers non exposes

Ces scripts sont utilises en interne mais pas directement accessibles via MCP:

| Script | Role |
|--------|------|
| `vm-controller/common.sh` | Fonctions communes (virsh, SSH, logging) |
| `backup-manager/common.sh` | Fonctions communes (borg, locks, notifications) |
| `vm-controller/test-agent.sh` | Tests d'integration de l'agent VM |
| `backup-manager/test-agent.sh` | Tests d'integration de l'agent backup |
| `vm-controller/open-ollama-port.sh` | Ouverture du port Ollama dans le firewall VM |
| `vm-controller/vm-nat-fix.sh` | Correction des regles NAT libvirt |
| `vm-controller/vm-check-firstboot*.sh` | Verification de l'etat de firstboot |

## Configuration

- Timeouts: `src/config.ts` (TIMEOUTS)
- Permissions sudo: `src/config.ts` (TOOL_PERMISSIONS)
- Retry: `src/config.ts` (RETRY_CONFIG)
- Config locale: `scripts/config.env` (copier depuis `scripts/config.env.example`)

## Logs

Les logs JSON structures sont ecrits dans:
1. `/var/log/mcp-agents/` (si accessible en ecriture)
2. `~/.local/state/mcp-agents/` (fallback utilisateur)
3. `/tmp/mcp-agents-logs/` (fallback final)

## Installation et demarrage

```bash
cd scripts/agents/mcp-server
npm install
npm run build

# Test local
node dist/index.js
```

La configuration MCP pour Claude Code se fait dans `.claude/settings.local.json`
(voir le CLAUDE.md a la racine du depot pour les details).
