/**
 * Outils MCP pour Backup-Manager
 */

import { z } from 'zod';
import { PATHS } from '../config.js';
import { execute } from '../utils/executor.js';
import {
  backupCreateSchema,
  backupListSchema,
  backupRestoreSchema,
  backupVerifySchema,
  backupCleanSchema,
  backupStatusSchema,
  type BackupCreateParams,
  type BackupListParams,
  type BackupRestoreParams,
  type BackupVerifyParams,
  type BackupCleanParams,
  type BackupStatusParams
} from '../utils/validation.js';

// Type pour la définition d'un outil MCP
export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: z.ZodType;
  handler: (params: unknown) => Promise<ToolResult>;
}

export interface ToolResult {
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
}

// Helper pour formater le résultat
function formatResult(result: Awaited<ReturnType<typeof execute>>): ToolResult {
  const output = result.success
    ? result.stdout
    : `Erreur (code ${result.exitCode}): ${result.stderr || result.stdout}`;

  return {
    content: [{ type: 'text', text: output }],
    isError: !result.success
  };
}

// ========================================
// backup_create
// ========================================
async function backupCreateHandler(params: unknown): Promise<ToolResult> {
  const validated = backupCreateSchema.parse(params) as BackupCreateParams;

  const args: string[] = [validated.type];
  if (validated.comment) args.push(`--comment=${validated.comment}`);
  if (validated.verify) args.push('--verify');
  if (validated.notify) args.push('--notify');
  if (validated.dry_run) args.push('--dry-run');

  // Options spécifiques
  if (validated.type === 'vm-snapshot' && validated.vm) {
    args.push(`--vm=${validated.vm}`);
    if (validated.live) args.push('--live');
  }
  if (validated.type === 'manual') {
    if (validated.source) args.push(`--source=${validated.source}`);
    if (validated.dest) args.push(`--dest=${validated.dest}`);
  }

  const result = await execute({
    tool: 'backup_create',
    script: `${PATHS.BACKUP_MANAGER}/backup-create.sh`,
    args,
    toolTimeoutMs: validated.timeout_ms
  });

  return formatResult(result);
}

export const backupCreate: ToolDefinition = {
  name: 'backup_create',
  description: 'Crée un backup (timeshift, borg, vm-snapshot, ou manual)',
  inputSchema: backupCreateSchema,
  handler: backupCreateHandler
};

// ========================================
// backup_list
// ========================================
async function backupListHandler(params: unknown): Promise<ToolResult> {
  const validated = backupListSchema.parse(params) as BackupListParams;

  const args: string[] = [];
  if (validated.all) args.push('--all');
  if (validated.type) args.push(`--type=${validated.type}`);
  if (validated.detailed) args.push('--detailed');
  if (validated.limit !== 20) args.push(`--limit=${validated.limit}`);
  if (validated.sort !== 'date') args.push(`--sort=${validated.sort}`);

  const result = await execute({
    tool: 'backup_list',
    script: `${PATHS.BACKUP_MANAGER}/backup-list.sh`,
    args
  });

  return formatResult(result);
}

export const backupList: ToolDefinition = {
  name: 'backup_list',
  description: 'Liste tous les backups disponibles (par type ou tous)',
  inputSchema: backupListSchema,
  handler: backupListHandler
};

// ========================================
// backup_restore
// ========================================
async function backupRestoreHandler(params: unknown): Promise<ToolResult> {
  const validated = backupRestoreSchema.parse(params) as BackupRestoreParams;

  const args = [validated.type, validated.identifier];
  if (validated.dry_run) args.push('--dry-run');
  if (validated.force) args.push('--force');
  if (validated.partial) args.push(`--partial=${validated.partial}`);
  if (validated.target) args.push(`--target=${validated.target}`);
  if (validated.skip_pre_snapshot) args.push('--skip-pre-snapshot');

  const result = await execute({
    tool: 'backup_restore',
    script: `${PATHS.BACKUP_MANAGER}/backup-restore.sh`,
    args
  });

  return formatResult(result);
}

export const backupRestore: ToolDefinition = {
  name: 'backup_restore',
  description: 'Restaure un backup (ATTENTION: opération destructive!)',
  inputSchema: backupRestoreSchema,
  handler: backupRestoreHandler
};

// ========================================
// backup_verify
// ========================================
async function backupVerifyHandler(params: unknown): Promise<ToolResult> {
  const validated = backupVerifySchema.parse(params) as BackupVerifyParams;

  const args: string[] = [];
  if (validated.type && validated.type !== 'all') args.push(validated.type);
  if (validated.deep) args.push('--deep');
  if (validated.quick) args.push('--quick');
  if (validated.backup_id) args.push(`--backup=${validated.backup_id}`);

  const result = await execute({
    tool: 'backup_verify',
    script: `${PATHS.BACKUP_MANAGER}/backup-verify.sh`,
    args,
    toolTimeoutMs: validated.timeout_ms
  });

  return formatResult(result);
}

export const backupVerify: ToolDefinition = {
  name: 'backup_verify',
  description: 'Vérifie l\'intégrité des backups',
  inputSchema: backupVerifySchema,
  handler: backupVerifyHandler
};

// ========================================
// backup_clean
// ========================================
async function backupCleanHandler(params: unknown): Promise<ToolResult> {
  const validated = backupCleanSchema.parse(params) as BackupCleanParams;

  const args: string[] = [validated.type];
  if (validated.dry_run) args.push('--dry-run');
  if (validated.force) args.push('--force');
  if (validated.keep_last) args.push(`--keep-last=${validated.keep_last}`);

  const result = await execute({
    tool: 'backup_clean',
    script: `${PATHS.BACKUP_MANAGER}/backup-clean.sh`,
    args
  });

  return formatResult(result);
}

export const backupClean: ToolDefinition = {
  name: 'backup_clean',
  description: 'Applique les politiques de rétention et supprime les anciens backups',
  inputSchema: backupCleanSchema,
  handler: backupCleanHandler
};

// ========================================
// backup_status
// ========================================
async function backupStatusHandler(params: unknown): Promise<ToolResult> {
  const validated = backupStatusSchema.parse(params) as BackupStatusParams;

  const args: string[] = [];
  // Note: --watch n'est pas supporté en mode MCP (interactif)
  if (validated.compact) args.push('--compact');

  const result = await execute({
    tool: 'backup_status',
    script: `${PATHS.BACKUP_MANAGER}/backup-status.sh`,
    args
  });

  return formatResult(result);
}

export const backupStatus: ToolDefinition = {
  name: 'backup_status',
  description: 'Affiche le dashboard global des backups (status, espace, alertes)',
  inputSchema: backupStatusSchema,
  handler: backupStatusHandler
};

// ========================================
// Export de tous les outils
// ========================================
export const backupManagerTools: ToolDefinition[] = [
  backupCreate,
  backupList,
  backupRestore,
  backupVerify,
  backupClean,
  backupStatus
];
