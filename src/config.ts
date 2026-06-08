/**
 * Configuration centrale du serveur MCP
 */

import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Chemins vers les agents
export const PATHS = {
  AGENTS_DIR: resolve(__dirname, '../../'),
  VM_CONTROLLER: resolve(__dirname, '../../vm-controller'),
  BACKUP_MANAGER: resolve(__dirname, '../../backup-manager'),
  KVM_SCRIPTS: resolve(__dirname, '../../../kvm'),
  LOG_DIR: '/var/log/mcp-agents',
} as const;

// Timeouts par outil (en ms)
export const TIMEOUTS: Record<string, number> = {
  // VM Controller
  vm_start: 300_000,      // 5 min (attente SSH)
  vm_stop: 120_000,       // 2 min
  vm_status: 30_000,      // 30s
  vm_exec: 300_000,       // 5 min
  vm_copy: 300_000,       // 5 min
  vm_snapshot: 120_000,   // 2 min
  vm_verify: 300_000,     // 5 min (vérification complète)
  vm_clone: 600_000,      // 10 min (clone complet)
  vm_clone_system: 1800_000, // 30 min (clone système entier)
  vm_export: 900_000,     // 15 min (export + virt-sysprep + tarball)
  vm_import: 600_000,     // 10 min (extraction + copie + virsh define)

  // Backup Manager
  backup_create: 600_000,  // 10 min
  backup_list: 60_000,     // 1 min
  backup_restore: 900_000, // 15 min
  backup_verify: 300_000,  // 5 min
  backup_clean: 300_000,   // 5 min
  backup_status: 60_000,   // 1 min

  // Default
  default: 60_000          // 1 min
};

// Permissions et flags par outil
export interface ToolPermission {
  requiresSudo: boolean;
  dangerous: boolean;
  description: string;
}

export const TOOL_PERMISSIONS: Record<string, ToolPermission> = {
  // VM Controller - lecture
  vm_status: {
    requiresSudo: false,
    dangerous: false,
    description: 'Affiche le status d\'une VM'
  },

  // VM Controller - modification
  vm_start: {
    requiresSudo: false,
    dangerous: false,
    description: 'Démarre une VM'
  },
  vm_stop: {
    requiresSudo: false,
    dangerous: true,
    description: 'Arrête une VM (peut causer perte de données non sauvegardées)'
  },
  vm_exec: {
    requiresSudo: false,
    dangerous: false,
    description: 'Exécute une commande dans une VM'
  },
  vm_copy: {
    requiresSudo: false,
    dangerous: false,
    description: 'Copie des fichiers vers/depuis une VM'
  },
  vm_snapshot: {
    requiresSudo: false,
    dangerous: false,
    description: 'Gère les snapshots d\'une VM'
  },
  vm_verify: {
    requiresSudo: false,
    dangerous: false,
    description: 'Vérifie qu\'une VM est une copie fidèle du système hôte'
  },
  vm_clone: {
    requiresSudo: true,
    dangerous: false,
    description: 'Clone une VM existante'
  },
  vm_clone_system: {
    requiresSudo: true,
    dangerous: true,
    description: 'Clone le système hôte vers une VM (opération longue)'
  },
  vm_export: {
    requiresSudo: false,
    dangerous: false,
    description: 'Exporte une VM dans une archive portable avec sanitarisation (mode classic ou exam)'
  },
  vm_import: {
    requiresSudo: true,   // besoin root pour cp vers /var/lib/libvirt/images/
    dangerous: false,
    description: 'Importe une VM depuis une archive exportée par vm_export'
  },

  // Backup Manager - lecture
  backup_status: {
    requiresSudo: true,
    dangerous: false,
    description: 'Affiche le dashboard des backups'
  },
  backup_list: {
    requiresSudo: true,
    dangerous: false,
    description: 'Liste les backups disponibles'
  },
  backup_verify: {
    requiresSudo: true,
    dangerous: false,
    description: 'Vérifie l\'intégrité des backups'
  },

  // Backup Manager - modification
  backup_create: {
    requiresSudo: true,
    dangerous: false,
    description: 'Crée un nouveau backup'
  },

  // Backup Manager - dangereux
  backup_restore: {
    requiresSudo: true,
    dangerous: true,
    description: 'Restaure un backup (DESTRUCTIF)'
  },
  backup_clean: {
    requiresSudo: true,
    dangerous: true,
    description: 'Supprime des backups selon la rétention'
  },
};

// Configuration retry
export const RETRY_CONFIG = {
  // Opérations idempotentes avec retry
  retryable: ['vm_status', 'backup_status', 'backup_list', 'backup_verify'],
  maxRetries: 3,
  backoffMs: [1000, 2000, 5000],

  // Opérations sans retry (modifications)
  nonRetryable: ['vm_stop', 'vm_start', 'vm_snapshot', 'backup_restore', 'backup_clean', 'backup_create']
} as const;

// Codes d'erreur
export enum ErrorCode {
  SUCCESS = 'SUCCESS',
  VALIDATION_ERROR = 'VALIDATION_ERROR',
  TIMEOUT = 'TIMEOUT',
  PERMISSION_DENIED = 'PERMISSION_DENIED',
  VM_NOT_FOUND = 'VM_NOT_FOUND',
  BACKUP_NOT_FOUND = 'BACKUP_NOT_FOUND',
  SCRIPT_ERROR = 'SCRIPT_ERROR',
  LOCK_CONFLICT = 'LOCK_CONFLICT',
  UNKNOWN_ERROR = 'UNKNOWN_ERROR'
}

// Mapping exit codes scripts -> ErrorCode
export const EXIT_CODE_MAP: Record<number, ErrorCode> = {
  0: ErrorCode.SUCCESS,
  1: ErrorCode.SCRIPT_ERROR,
  2: ErrorCode.TIMEOUT,
  3: ErrorCode.LOCK_CONFLICT,
  4: ErrorCode.SCRIPT_ERROR, // Espace insuffisant
  5: ErrorCode.SCRIPT_ERROR, // Vérification échouée
  6: ErrorCode.SCRIPT_ERROR, // Annulé par utilisateur
};
