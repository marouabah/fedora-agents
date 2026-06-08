/**
 * Outils MCP pour VM-Controller
 */

import { z } from 'zod';
import { PATHS } from '../config.js';
import { execute, buildArgs } from '../utils/executor.js';
import {
  vmStartSchema,
  vmStopSchema,
  vmDestroySchema,
  vmStatusSchema,
  vmExecSchema,
  vmCopySchema,
  vmSnapshotSchema,
  vmVerifySchema,
  vmCloneSchema,
  vmCloneSystemSchema,
  type VmStartParams,
  type VmStopParams,
  type VmDestroyParams,
  type VmStatusParams,
  type VmExecParams,
  type VmCopyParams,
  type VmSnapshotParams,
  type VmVerifyParams,
  type VmCloneParams,
  type VmCloneSystemParams,
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
// vm_start
// ========================================
async function vmStartHandler(params: unknown): Promise<ToolResult> {
  const validated = vmStartSchema.parse(params) as VmStartParams;

  const args = [validated.vm_name];
  if (validated.wait_ssh) args.push('--wait-ssh');
  else if (validated.wait_ip) args.push('--wait-ip');
  if (validated.timeout !== 300) args.push(`--timeout=${validated.timeout}`);

  const result = await execute({
    tool: 'vm_start',
    script: `${PATHS.VM_CONTROLLER}/vm-start.sh`,
    args
  });

  return formatResult(result);
}

export const vmStart: ToolDefinition = {
  name: 'vm_start',
  description: 'Démarre une VM KVM et attend optionnellement que SSH soit accessible',
  inputSchema: vmStartSchema,
  handler: vmStartHandler
};

// ========================================
// vm_stop
// ========================================
async function vmStopHandler(params: unknown): Promise<ToolResult> {
  const validated = vmStopSchema.parse(params) as VmStopParams;

  const args = [validated.vm_name];
  if (validated.force) args.push('--force');
  if (validated.wait) args.push('--wait');
  if (validated.timeout !== 60) args.push(`--timeout=${validated.timeout}`);

  const result = await execute({
    tool: 'vm_stop',
    script: `${PATHS.VM_CONTROLLER}/vm-stop.sh`,
    args
  });

  return formatResult(result);
}

export const vmStop: ToolDefinition = {
  name: 'vm_stop',
  description: 'Arrête une VM KVM proprement (ou force l\'arrêt avec --force)',
  inputSchema: vmStopSchema,
  handler: vmStopHandler
};

// ========================================
// vm_destroy
// ========================================
async function vmDestroyHandler(params: unknown): Promise<ToolResult> {
  const validated = vmDestroySchema.parse(params) as VmDestroyParams;

  const args = [validated.vm_name];
  if (validated.force) args.push('--force');
  if (validated.keep_storage) args.push('--keep-storage');
  // Toujours passer --yes car MCP est non-interactif
  args.push('--yes');

  const result = await execute({
    tool: 'vm_destroy',
    script: `${PATHS.VM_CONTROLLER}/vm-destroy.sh`,
    args
  });

  return formatResult(result);
}

export const vmDestroy: ToolDefinition = {
  name: 'vm_destroy',
  description: 'Supprime complètement une VM KVM (définition + stockage)',
  inputSchema: vmDestroySchema,
  handler: vmDestroyHandler
};

// ========================================
// vm_status
// ========================================
async function vmStatusHandler(params: unknown): Promise<ToolResult> {
  const validated = vmStatusSchema.parse(params) as VmStatusParams;

  const args: string[] = [];
  // Si vm_name est fourni, l'ajouter; sinon le script listera toutes les VMs
  if (validated.vm_name) {
    args.push(validated.vm_name);
  }
  if (validated.detailed) args.push('--detailed');
  if (validated.json) args.push('--json');

  const result = await execute({
    tool: 'vm_status',
    script: `${PATHS.VM_CONTROLLER}/vm-status.sh`,
    args
  });

  return formatResult(result);
}

export const vmStatus: ToolDefinition = {
  name: 'vm_status',
  description: 'Affiche le status et les informations d\'une VM (IP, SSH, ressources). Sans vm_name, liste toutes les VMs.',
  inputSchema: vmStatusSchema,
  handler: vmStatusHandler
};

// ========================================
// vm_exec
// ========================================
async function vmExecHandler(params: unknown): Promise<ToolResult> {
  const validated = vmExecSchema.parse(params) as VmExecParams;

  const args = [validated.vm_name, validated.command];
  if (validated.user) args.push(`--user=${validated.user}`);
  if (validated.sudo) args.push('--sudo');
  if (validated.capture) args.push('--capture');
  if (validated.timeout !== 300) args.push(`--timeout=${validated.timeout}`);

  const result = await execute({
    tool: 'vm_exec',
    script: `${PATHS.VM_CONTROLLER}/vm-exec.sh`,
    args
  });

  return formatResult(result);
}

export const vmExec: ToolDefinition = {
  name: 'vm_exec',
  description: 'Exécute une commande dans une VM via SSH',
  inputSchema: vmExecSchema,
  handler: vmExecHandler
};

// ========================================
// vm_copy
// ========================================
async function vmCopyHandler(params: unknown): Promise<ToolResult> {
  const validated = vmCopySchema.parse(params) as VmCopyParams;

  const args = [validated.vm_name, validated.source, validated.dest];
  if (validated.direction === 'from_vm') args.push('--from-vm');
  else args.push('--to-vm');
  if (validated.recursive) args.push('--recursive');
  if (validated.checksum) args.push('--checksum');
  if (validated.preserve) args.push('--preserve');

  const result = await execute({
    tool: 'vm_copy',
    script: `${PATHS.VM_CONTROLLER}/vm-copy.sh`,
    args
  });

  return formatResult(result);
}

export const vmCopy: ToolDefinition = {
  name: 'vm_copy',
  description: 'Copie des fichiers entre l\'hôte et une VM via SCP',
  inputSchema: vmCopySchema,
  handler: vmCopyHandler
};

// ========================================
// vm_snapshot
// ========================================
async function vmSnapshotHandler(params: unknown): Promise<ToolResult> {
  const validated = vmSnapshotSchema.parse(params) as VmSnapshotParams;

  const args = [validated.vm_name, validated.action];
  if (validated.snapshot_name) args.push(validated.snapshot_name);
  if (validated.description) args.push(`--description=${validated.description}`);
  if (validated.live) args.push('--live');
  // Toujours passer --yes pour les actions destructives (MCP est non-interactif)
  const destructiveActions = ['delete', 'restore', 'delete-all'];
  if (validated.yes || destructiveActions.includes(validated.action)) args.push('--yes');

  const result = await execute({
    tool: 'vm_snapshot',
    script: `${PATHS.VM_CONTROLLER}/vm-snapshot.sh`,
    args
  });

  return formatResult(result);
}

export const vmSnapshot: ToolDefinition = {
  name: 'vm_snapshot',
  description: 'Gère les snapshots d\'une VM (create, list, restore, delete)',
  inputSchema: vmSnapshotSchema,
  handler: vmSnapshotHandler
};

// ========================================
// vm_verify
// ========================================
async function vmVerifyHandler(params: unknown): Promise<ToolResult> {
  const validated = vmVerifySchema.parse(params) as VmVerifyParams;

  const args: string[] = [];
  if (validated.self_check) {
    args.push('--self-check');
  } else {
    args.push('--vm', validated.vm_name);
    if (validated.ip) args.push('--ip', validated.ip);
    args.push('--user', validated.user);
  }
  if (validated.verbose) args.push('--verbose');
  if (validated.quick) args.push('--quick');
  if (validated.save_report) args.push('--save-report');
  if (validated.compare_packages) args.push('--compare-packages');
  if (validated.compare_content) args.push('--compare-content');

  const result = await execute({
    tool: 'vm_verify',
    script: `${PATHS.KVM_SCRIPTS}/verify-vm-clone.sh`,
    args
  });

  return formatResult(result);
}

export const vmVerify: ToolDefinition = {
  name: 'vm_verify',
  description: 'Vérifie qu\'une VM clonée est une copie fidèle du système hôte',
  inputSchema: vmVerifySchema,
  handler: vmVerifyHandler
};

// ========================================
// vm_clone
// ========================================
async function vmCloneHandler(params: unknown): Promise<ToolResult> {
  const validated = vmCloneSchema.parse(params) as VmCloneParams;

  const args = [validated.source_vm, validated.new_vm_name];
  if (validated.start) args.push('--start');
  if (validated.autostart) args.push('--autostart');
  if (validated.linked) args.push('--linked');
  if (validated.network !== 'default') args.push(`--network=${validated.network}`);

  // Collecter les jalons de progression pour les inclure dans la réponse
  const progressLog: string[] = [];
  let lastLoggedPct = -1;
  const onProgress = (percent: number): void => {
    const rounded = Math.floor(percent / 25) * 25; // jalons à 0%, 25%, 50%, 75%, 100%
    if (rounded > lastLoggedPct) {
      lastLoggedPct = rounded;
      progressLog.push(`${rounded}%`);
    }
  };

  const startTime = Date.now();

  const result = await execute({
    tool: 'vm_clone',
    script: `${PATHS.KVM_SCRIPTS}/kvm-clone.sh`,
    args,
    toolTimeoutMs: validated.timeout_ms,
    onProgress
  });

  const durationSeconds = Math.round((Date.now() - startTime) / 1000);

  if (!result.success) {
    return formatResult(result);
  }

  // Réponse enrichie avec métadonnées du clonage
  const cloneType = validated.linked ? 'linked' : 'full';
  const summary = {
    success: true,
    vm_name: validated.new_vm_name,
    source_vm: validated.source_vm,
    type: cloneType,
    duration_seconds: durationSeconds,
    progress_log: progressLog.length > 0 ? progressLog : ['linked-instant'],
    output: result.stdout
  };

  return {
    content: [{ type: 'text', text: JSON.stringify(summary, null, 2) }]
  };
}

export const vmClone: ToolDefinition = {
  name: 'vm_clone',
  description: 'Clone une VM KVM existante (complet ou lié)',
  inputSchema: vmCloneSchema,
  handler: vmCloneHandler
};

// ========================================
// vm_clone_system
// ========================================
async function vmCloneSystemHandler(params: unknown): Promise<ToolResult> {
  const validated = vmCloneSystemSchema.parse(params) as VmCloneSystemParams;

  const args: string[] = [];
  // Utiliser les options courtes avec espace (format attendu par le script)
  args.push('-n', validated.name);
  args.push('-d', validated.disk_size);
  args.push('-m', String(validated.memory));
  args.push('-c', String(validated.cpus));
  if (validated.hostname) args.push('--hostname', validated.hostname);
  if (validated.username) args.push('--username', validated.username);
  if (validated.dry_run) args.push('--dry-run');
  // Toujours passer --yes car MCP est non-interactif
  args.push('--yes');

  const result = await execute({
    tool: 'vm_clone_system',
    script: `${PATHS.KVM_SCRIPTS}/kvm-clone-system.sh`,
    args,
    toolTimeoutMs: validated.timeout_ms
  });

  return formatResult(result);
}

export const vmCloneSystem: ToolDefinition = {
  name: 'vm_clone_system',
  description: 'Clone le système hôte entier vers une VM KVM bootable',
  inputSchema: vmCloneSystemSchema,
  handler: vmCloneSystemHandler
};

// ========================================
// Export de tous les outils
// ========================================
export const vmControllerTools: ToolDefinition[] = [
  vmStart,
  vmStop,
  vmDestroy,
  vmStatus,
  vmExec,
  vmCopy,
  vmSnapshot,
  vmVerify,
  vmClone,
  vmCloneSystem
];
