/**
 * Outils MCP pour la portabilite des VMs (export / import)
 */

import { z } from 'zod';
import { PATHS } from '../config.js';
import { execute } from '../utils/executor.js';
import {
  vmExportSchema,
  vmImportSchema,
  type VmExportParams,
  type VmImportParams
} from '../utils/validation.js';
import type { ToolDefinition, ToolResult } from './vm-controller.js';

// Helper pour formater le resultat
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
// vm_export
// ========================================

async function vmExportHandler(params: unknown): Promise<ToolResult> {
  const validated = vmExportSchema.parse(params) as VmExportParams;

  const args = [validated.vm_name];
  args.push(`--mode=${validated.mode}`);
  if (validated.output_path) args.push(`--output=${validated.output_path}`);
  if (validated.force) args.push('--force');
  if (validated.dry_run) args.push('--dry-run');
  // Mode custom: passer la liste des operations
  if (validated.mode === 'custom' && validated.operations && validated.operations.length > 0) {
    args.push(`--operations=${validated.operations.join(',')}`);
  }
  // Firstboot explicite (mode custom avec comptes supprimes)
  if (validated.firstboot) args.push('--firstboot');

  const result = await execute({
    tool: 'vm_export',
    script: `${PATHS.VM_CONTROLLER}/vm-export.sh`,
    args
  });

  return formatResult(result);
}

export const vmExport: ToolDefinition = {
  name: 'vm_export',
  description: [
    'Exporte une VM KVM dans une archive portable (.tar.gz) avec sanitarisation des donnees sensibles.',
    'Mode classic: supprime tous les comptes utilisateurs, passwords, keyrings, cles SSH users.',
    '  Un script de configuration s\'execute au premier demarrage (creation user + password root).',
    'Mode exam: conserve les comptes et privileges, sanitarise machine-id/SSH-host-keys/reseau/logs.',
    'Mode custom: choisir les operations virt-sysprep via le parametre operations[].',
    '  Avec firstboot=true: installe aussi le script de configuration premier demarrage.',
    'Effectue un test pre-export (integrite disque, espace) et un test post-export (archive OK).',
    'Archive generee: <vm>-export-YYYYMMDD-HHMMSS-<mode>.tar.gz dans ~/vm-exports/ par defaut.'
  ].join(' '),
  inputSchema: vmExportSchema,
  handler: vmExportHandler
};

// ========================================
// vm_import
// ========================================

async function vmImportHandler(params: unknown): Promise<ToolResult> {
  const validated = vmImportSchema.parse(params) as VmImportParams;

  const args = [validated.archive_path];
  if (validated.new_name) args.push(`--name=${validated.new_name}`);
  if (validated.pool_dir) args.push(`--pool=${validated.pool_dir}`);
  if (validated.start) args.push('--start');
  if (validated.dry_run) args.push('--dry-run');

  const result = await execute({
    tool: 'vm_import',
    script: `${PATHS.VM_CONTROLLER}/vm-import.sh`,
    args
  });

  return formatResult(result);
}

export const vmImport: ToolDefinition = {
  name: 'vm_import',
  description: [
    'Importe une VM KVM depuis une archive exportee par vm_export.',
    'Effectue un test pre-import (integrite archive + disque qcow2) et post-import (VM definie + disque OK).',
    'Genere un nouveau UUID et une nouvelle adresse MAC automatiquement.',
    'Le disque est copie dans /var/lib/libvirt/images/ par defaut.',
    'Avec --start: demarre la VM et attend SSH apres l\'import.'
  ].join(' '),
  inputSchema: vmImportSchema,
  handler: vmImportHandler
};

// ========================================
// Export
// ========================================

export const vmPortabilityTools: ToolDefinition[] = [
  vmExport,
  vmImport
];
