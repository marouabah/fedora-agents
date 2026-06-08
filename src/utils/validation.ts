/**
 * Schemas de validation Zod pour tous les outils
 */

import { z } from 'zod';

// Helper pour accepter boolean ou string "true"/"false"
const flexibleBoolean = z.preprocess(
  (val) => {
    if (typeof val === 'string') {
      if (val.toLowerCase() === 'true') return true;
      if (val.toLowerCase() === 'false') return false;
    }
    return val;
  },
  z.boolean()
);

// Pattern commun pour les noms de VM
const vmNamePattern = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;
const vmNameSchema = z.string()
  .min(1, 'Le nom de VM est requis')
  .max(64, 'Le nom de VM ne doit pas dépasser 64 caractères')
  .regex(vmNamePattern, 'Caractères autorisés: a-z, A-Z, 0-9, _, - (doit commencer par alphanumérique)');

// Pattern pour les noms de snapshot
const snapshotNamePattern = /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/;
const snapshotNameSchema = z.string()
  .min(1)
  .max(128)
  .regex(snapshotNamePattern, 'Caractères autorisés: a-z, A-Z, 0-9, _, -');

// Pattern pour les chemins de fichiers (sécurisé)
const safePathPattern = /^[a-zA-Z0-9/_.-]+$/;
const safePathSchema = z.string()
  .min(1)
  .max(4096)
  .regex(safePathPattern, 'Chemin contient des caractères non autorisés')
  .refine(path => !path.includes('..'), 'Les chemins relatifs (..) ne sont pas autorisés');

// ========================================
// VM Controller Schemas
// ========================================

export const vmStartSchema = z.object({
  vm_name: vmNameSchema,
  wait_ssh: z.boolean().optional().default(false),
  wait_ip: z.boolean().optional().default(false),
  timeout: z.number().min(10).max(600).optional().default(300)
});

export const vmStopSchema = z.object({
  vm_name: vmNameSchema,
  force: z.boolean().optional().default(false),
  wait: z.boolean().optional().default(true),
  timeout: z.number().min(10).max(300).optional().default(60)
});

export const vmDestroySchema = z.object({
  vm_name: vmNameSchema,
  force: z.boolean().optional().default(false),
  keep_storage: z.boolean().optional().default(false)
});

// Schema spécial pour vm_status: accepte null, chaîne vide, undefined, ou nom valide
const vmNameOptionalSchema = z.preprocess(
  (val) => (val === null || val === '' || val === undefined) ? undefined : val,
  z.string()
    .max(64, 'Le nom de VM ne doit pas dépasser 64 caractères')
    .optional()
).refine(val => val === undefined || vmNamePattern.test(val), {
  message: 'Caractères autorisés: a-z, A-Z, 0-9, _, - (doit commencer par alphanumérique)'
});

export const vmStatusSchema = z.object({
  vm_name: vmNameOptionalSchema,  // Optionnel: si absent ou vide, liste toutes les VMs
  detailed: flexibleBoolean.optional().default(false),
  json: flexibleBoolean.optional().default(false)
});

export const vmExecSchema = z.object({
  vm_name: vmNameSchema,
  command: z.string().min(1).max(4096),
  user: z.string().min(1).max(64).optional(),
  sudo: z.boolean().optional().default(false),
  timeout: z.number().min(10).max(600).optional().default(300),
  capture: z.boolean().optional().default(false)
});

export const vmCopySchema = z.object({
  vm_name: vmNameSchema,
  source: safePathSchema,
  dest: safePathSchema,
  direction: z.enum(['to_vm', 'from_vm']).default('to_vm'),
  recursive: z.boolean().optional().default(false),
  checksum: z.boolean().optional().default(false),
  preserve: z.boolean().optional().default(false)
});

export const vmSnapshotSchema = z.object({
  vm_name: vmNameSchema,
  action: z.enum(['create', 'list', 'restore', 'delete', 'delete-all']),
  snapshot_name: snapshotNameSchema.optional(),
  description: z.string().max(256).optional(),
  live: z.boolean().optional().default(false),
  yes: z.boolean().optional().default(false)
}).refine(
  data => {
    // snapshot_name requis pour certaines actions
    if (['create', 'restore', 'delete'].includes(data.action)) {
      return !!data.snapshot_name;
    }
    return true;
  },
  { message: 'snapshot_name est requis pour cette action' }
);

// ========================================
// VM Clone & Verify Schemas
// ========================================

export const vmVerifySchema = z.object({
  vm_name: vmNameSchema.optional().default('neutron-clone'),
  ip: z.string().ip().optional(),
  user: z.string().min(1).max(64).optional().default('amineutron'),
  self_check: z.boolean().optional().default(false),
  verbose: z.boolean().optional().default(false),
  quick: z.boolean().optional().default(false),
  save_report: z.boolean().optional().default(false),
  compare_packages: z.boolean().optional().default(false),
  compare_content: z.boolean().optional().default(false)
});

export const vmCloneSchema = z.object({
  source_vm: vmNameSchema,
  new_vm_name: vmNameSchema,
  start: z.boolean().optional().default(false),
  autostart: z.boolean().optional().default(false),
  linked: z.boolean().optional().default(false),
  network: z.string().min(1).max(64).optional().default('default'),
  timeout_ms: z.number().min(10_000).max(3_600_000).optional(),
  /** Identifiant optionnel de session de tracking MCP pour suivi de progression */
  tracking_session_id: z.string().min(1).max(256).optional()
});

export const vmCloneSystemSchema = z.object({
  name: vmNameSchema.optional().default('neutron-clone'),
  disk_size: z.string().regex(/^\d+[GM]$/, 'Format: 60G ou 8192M').optional().default('60G'),
  memory: z.number().min(1024).max(65536).optional().default(8192),
  cpus: z.number().min(1).max(32).optional().default(4),
  hostname: z.string().min(1).max(64).optional(),
  username: z.string().min(1).max(64).optional(),
  dry_run: z.boolean().optional().default(false),
  timeout_ms: z.number().min(60_000).max(7_200_000).optional()
});

// ========================================
// Backup Manager Schemas
// ========================================

const backupTypeSchema = z.enum(['timeshift', 'borg', 'vm-snapshot', 'manual']);

export const backupCreateSchema = z.object({
  type: backupTypeSchema,
  comment: z.string().max(256).optional(),
  verify: z.boolean().optional().default(false),
  notify: z.boolean().optional().default(false),
  dry_run: z.boolean().optional().default(false),
  // Options spécifiques vm-snapshot
  vm: vmNameSchema.optional(),
  live: z.boolean().optional(),
  // Options spécifiques manual
  source: safePathSchema.optional(),
  dest: safePathSchema.optional(),
  timeout_ms: z.number().min(60_000).max(3_600_000).optional()
}).refine(
  data => {
    if (data.type === 'vm-snapshot' && !data.vm) {
      return false;
    }
    if (data.type === 'manual' && !data.source) {
      return false;
    }
    return true;
  },
  { message: 'Paramètres requis manquants pour ce type de backup' }
);

export const backupListSchema = z.object({
  all: z.boolean().optional().default(false),
  type: backupTypeSchema.optional(),
  detailed: z.boolean().optional().default(false),
  limit: z.number().min(1).max(100).optional().default(20),
  sort: z.enum(['date', 'type', 'size']).optional().default('date')
});

// Identifiant backup : timeshift (2026-06-09_03-00-01), borg (archive::name), snapshot (snap-name)
const backupIdentifierPattern = /^[a-zA-Z0-9_.:/-]+$/;
const backupIdentifierSchema = z.string()
  .min(1)
  .max(256)
  .regex(backupIdentifierPattern, 'Identifiant contient des caractères non autorisés')
  .refine(id => !id.includes('..'), 'Les chemins relatifs (..) ne sont pas autorisés');

export const backupRestoreSchema = z.object({
  type: backupTypeSchema,
  identifier: backupIdentifierSchema,
  dry_run: z.boolean().optional().default(false),
  force: z.boolean().optional().default(false),
  partial: safePathSchema.optional(),
  target: safePathSchema.optional(),
  skip_pre_snapshot: z.boolean().optional().default(false)
});

export const backupVerifySchema = z.object({
  type: z.enum(['timeshift', 'borg', 'vm', 'all']).optional().default('all'),
  deep: z.boolean().optional().default(false),
  quick: z.boolean().optional().default(false),
  backup_id: z.string().max(256).optional(),
  timeout_ms: z.number().min(30_000).max(1_800_000).optional()
});

export const backupCleanSchema = z.object({
  type: z.enum(['timeshift', 'borg', 'vm', 'manual', 'all']),
  dry_run: z.boolean().optional().default(false),
  force: z.boolean().optional().default(false),
  keep_last: z.number().min(1).max(100).optional()
});

export const backupStatusSchema = z.object({
  watch: z.boolean().optional().default(false),
  compact: z.boolean().optional().default(false)
});

// ========================================
// VM Portability Schemas (export / import)
// ========================================

export const vmExportSchema = z.object({
  vm_name: vmNameSchema,
  mode: z.enum(['classic', 'exam', 'custom']).optional().default('classic'),
  output_path: safePathSchema.optional(),
  force: z.boolean().optional().default(false),
  dry_run: z.boolean().optional().default(false),
  // Mode custom: liste des operations virt-sysprep a appliquer
  operations: z.array(z.string().min(1).max(64)).optional(),
  // Forcer l'injection du script firstboot (mode custom avec user-account selectionne)
  firstboot: z.boolean().optional().default(false)
});

export const vmImportSchema = z.object({
  archive_path: safePathSchema,
  new_name: vmNameSchema.optional(),
  pool_dir: safePathSchema.optional(),
  start: z.boolean().optional().default(false),
  dry_run: z.boolean().optional().default(false)
});

// ========================================
// Export des types inférés
// ========================================

export type VmStartParams = z.infer<typeof vmStartSchema>;
export type VmStopParams = z.infer<typeof vmStopSchema>;
export type VmDestroyParams = z.infer<typeof vmDestroySchema>;
export type VmStatusParams = z.infer<typeof vmStatusSchema>;
export type VmExecParams = z.infer<typeof vmExecSchema>;
export type VmCopyParams = z.infer<typeof vmCopySchema>;
export type VmSnapshotParams = z.infer<typeof vmSnapshotSchema>;
export type VmVerifyParams = z.infer<typeof vmVerifySchema>;
export type VmCloneParams = z.infer<typeof vmCloneSchema>;
export type VmCloneSystemParams = z.infer<typeof vmCloneSystemSchema>;

export type BackupCreateParams = z.infer<typeof backupCreateSchema>;
export type BackupListParams = z.infer<typeof backupListSchema>;
export type BackupRestoreParams = z.infer<typeof backupRestoreSchema>;
export type BackupVerifyParams = z.infer<typeof backupVerifySchema>;
export type BackupCleanParams = z.infer<typeof backupCleanSchema>;
export type BackupStatusParams = z.infer<typeof backupStatusSchema>;

export type VmExportParams = z.infer<typeof vmExportSchema>;
export type VmImportParams = z.infer<typeof vmImportSchema>;
