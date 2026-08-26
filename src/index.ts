#!/usr/bin/env node
/**
 * Serveur MCP pour les agents Fedora (VM-Controller & Backup-Manager)
 *
 * Ce serveur expose 12 outils pour gérer les VMs KVM et les backups
 * via le protocole MCP (Model Context Protocol).
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';

import { existsSync, mkdirSync, accessSync, constants } from 'fs';
import os from 'os';
import path from 'path';
import { logger } from './logger.js';
import { vmControllerTools } from './tools/vm-controller.js';
import { backupManagerTools } from './tools/backup-manager.js';
import { vmPortabilityTools } from './tools/vm-portability.js';
import { TOOL_PERMISSIONS, PATHS } from './config.js';

/**
 * Crée le répertoire de logs et retourne le chemin effectif.
 * Essaie d'abord le répertoire configuré (ex: /var/log/mcp-agents),
 * puis un fallback dans ~/.local/state, puis /tmp.
 */
function ensureLogDir(): string {
  const dirs = [
    PATHS.LOG_DIR,
    path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'mcp-agents')
  ];
  for (const dir of dirs) {
    try {
      mkdirSync(dir, { recursive: true });
      accessSync(dir, constants.W_OK);
      return dir;
    } catch {
      // essayer le suivant
    }
  }
  const fallback = '/tmp/mcp-agents-logs';
  try {
    mkdirSync(fallback, { recursive: true });
  } catch {
    // rien a faire, /tmp devrait toujours etre accessible
  }
  return fallback;
}

// Outil help pour lister les capacités
const helpTool = {
  name: 'help',
  description: 'Liste tous les outils disponibles avec leurs descriptions. Appelle cet outil en premier pour savoir ce que tu peux faire.',
  inputSchema: z.object({}),
  handler: async () => {
    const vmTools = vmControllerTools.map(t => `  - ${t.name}: ${t.description}`).join('\n');
    const backupTools = backupManagerTools.map(t => `  - ${t.name}: ${t.description}`).join('\n');
    const portabilityTools = vmPortabilityTools.map(t => `  - ${t.name}: ${t.description}`).join('\n');

    const helpText = `
╔══════════════════════════════════════════════════════════════╗
║              FEDORA-AGENTS MCP - AIDE                        ║
╚══════════════════════════════════════════════════════════════╝

🖥️  OUTILS VM (gestion des machines virtuelles KVM):
${vmTools}

💾 OUTILS BACKUP (gestion des sauvegardes):
${backupTools}

📦 OUTILS PORTABILITE (export / import de VMs):
${portabilityTools}

📋 EXEMPLES D'UTILISATION:
  - Lister les VMs: vm_status (sans paramètre)
  - Status d'une VM: vm_status avec vm_name="preprod"
  - Démarrer une VM: vm_start avec vm_name="preprod"
  - Status backups: backup_status (sans paramètre)
  - Lister backups: backup_list
  - Exporter une VM: vm_export avec vm_name="preprod" mode="classic"
  - Importer une VM: vm_import avec archive_path="/path/to/vm.tar.gz"

⚠️  IMPORTANT: Utilise ces outils pour les VMs et backups.
    N'utilise PAS filesystem pour les opérations VM/backup.
`;

    return {
      content: [{ type: 'text' as const, text: helpText }],
      isError: false
    };
  }
};

// Combine tous les outils
const allTools = [helpTool, ...vmControllerTools, ...backupManagerTools, ...vmPortabilityTools];

// Créer le serveur MCP
const server = new Server(
  {
    name: 'fedora-agents',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Handler: Liste des outils disponibles
server.setRequestHandler(ListToolsRequestSchema, async () => {
  logger.info('list_tools', { message: 'Listing available tools' });

  return {
    tools: allTools.map((tool) => {
      const permission = TOOL_PERMISSIONS[tool.name];
      const dangerWarning = permission?.dangerous
        ? ' ⚠️ ATTENTION: Opération potentiellement destructive!'
        : '';

      return {
        name: tool.name,
        description: tool.description + dangerWarning,
        inputSchema: zodToJsonSchema(tool.inputSchema),
      };
    }),
  };
});

// Handler: Appel d'un outil
server.setRequestHandler(CallToolRequestSchema, async (request): Promise<{
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
}> => {
  const { name, arguments: args } = request.params;

  logger.info('tool_call_received', {
    tool: name,
    params: args as Record<string, unknown>,
  });

  // Trouver l'outil
  const tool = allTools.find((t) => t.name === name);
  if (!tool) {
    logger.error('tool_not_found', { tool: name });
    return {
      content: [
        {
          type: 'text' as const,
          text: `Outil inconnu: ${name}. Outils disponibles: ${allTools.map((t) => t.name).join(', ')}`,
        },
      ],
      isError: true,
    };
  }

  try {
    // Exécuter l'outil
    const result = await tool.handler(args);
    return {
      content: result.content.map(c => ({ type: 'text' as const, text: c.text })),
      isError: result.isError,
    };
  } catch (error) {
    // Erreur de validation Zod
    if (error instanceof z.ZodError) {
      const errorMessages = error.errors
        .map((e) => `${e.path.join('.')}: ${e.message}`)
        .join('; ');

      logger.error('validation_error', {
        tool: name,
        error: errorMessages,
      });

      return {
        content: [
          {
            type: 'text' as const,
            text: `Erreur de validation: ${errorMessages}`,
          },
        ],
        isError: true,
      };
    }

    // Autre erreur
    const errorMessage = error instanceof Error ? error.message : String(error);
    logger.error('tool_error', {
      tool: name,
      error: errorMessage,
    });

    return {
      content: [
        {
          type: 'text' as const,
          text: `Erreur: ${errorMessage}`,
        },
      ],
      isError: true,
    };
  }
});

/**
 * Convertit un schema Zod en JSON Schema (simplifié)
 */
function zodToJsonSchema(schema: z.ZodType): Record<string, unknown> {
  // Pour les objets Zod, on utilise la méthode de description
  if (schema instanceof z.ZodObject) {
    const shape = schema.shape;
    const properties: Record<string, unknown> = {};
    const required: string[] = [];

    for (const [key, value] of Object.entries(shape)) {
      const zodValue = value as z.ZodType;
      properties[key] = zodTypeToJsonSchema(zodValue);

      // Vérifier si le champ est requis (pas optional)
      if (!(zodValue instanceof z.ZodOptional) && !(zodValue instanceof z.ZodDefault)) {
        required.push(key);
      }
    }

    return {
      type: 'object',
      properties,
      required: required.length > 0 ? required : undefined,
    };
  }

  return { type: 'object' };
}

function zodTypeToJsonSchema(zodType: z.ZodType): Record<string, unknown> {
  // Unwrap récursivement optional et default (peuvent être imbriqués)
  let innerType = zodType;

  while (innerType instanceof z.ZodOptional || innerType instanceof z.ZodDefault) {
    if (innerType instanceof z.ZodOptional) {
      innerType = innerType.unwrap();
    } else if (innerType instanceof z.ZodDefault) {
      innerType = innerType._def.innerType;
    }
  }

  // Types de base
  if (innerType instanceof z.ZodString) {
    return { type: 'string' };
  }
  if (innerType instanceof z.ZodNumber) {
    return { type: 'number' };
  }
  if (innerType instanceof z.ZodBoolean) {
    return { type: 'boolean' };
  }
  if (innerType instanceof z.ZodEnum) {
    return {
      type: 'string',
      enum: innerType._def.values,
    };
  }
  if (innerType instanceof z.ZodArray) {
    return {
      type: 'array',
      items: zodTypeToJsonSchema(innerType._def.type),
    };
  }

  return { type: 'string' };
}

/**
 * Verifie que chaque script référencé dans PATHS existe sur le disque.
 * Log un warning (non fatal) pour chaque script manquant.
 */
function validatePaths(): void {
  const checks: Array<{ label: string; path: string }> = [
    // VM Controller
    { label: 'vm-start',        path: `${PATHS.VM_CONTROLLER}/vm-start.sh` },
    { label: 'vm-stop',         path: `${PATHS.VM_CONTROLLER}/vm-stop.sh` },
    { label: 'vm-status',       path: `${PATHS.VM_CONTROLLER}/vm-status.sh` },
    { label: 'vm-exec',         path: `${PATHS.VM_CONTROLLER}/vm-exec.sh` },
    { label: 'vm-copy',         path: `${PATHS.VM_CONTROLLER}/vm-copy.sh` },
    { label: 'vm-snapshot',     path: `${PATHS.VM_CONTROLLER}/vm-snapshot.sh` },
    { label: 'vm-destroy',      path: `${PATHS.VM_CONTROLLER}/vm-destroy.sh` },
    { label: 'vm-export',       path: `${PATHS.VM_CONTROLLER}/vm-export.sh` },
    { label: 'vm-import',       path: `${PATHS.VM_CONTROLLER}/vm-import.sh` },
    // KVM (clonage / verification)
    { label: 'vm-verify',       path: `${PATHS.KVM_SCRIPTS}/verify-vm-clone.sh` },
    { label: 'kvm-clone',       path: `${PATHS.KVM_SCRIPTS}/kvm-clone.sh` },
    { label: 'kvm-clone-system',path: `${PATHS.KVM_SCRIPTS}/kvm-clone-system.sh` },
    { label: 'kvm-snapshot',    path: `${PATHS.KVM_SCRIPTS}/kvm-snapshot.sh` },
    // Backup Manager
    { label: 'backup-create',   path: `${PATHS.BACKUP_MANAGER}/backup-create.sh` },
    { label: 'backup-list',     path: `${PATHS.BACKUP_MANAGER}/backup-list.sh` },
    { label: 'backup-restore',  path: `${PATHS.BACKUP_MANAGER}/backup-restore.sh` },
    { label: 'backup-verify',   path: `${PATHS.BACKUP_MANAGER}/backup-verify.sh` },
    { label: 'backup-clean',    path: `${PATHS.BACKUP_MANAGER}/backup-clean.sh` },
    { label: 'backup-status',   path: `${PATHS.BACKUP_MANAGER}/backup-status.sh` },
    // KVM Scripts
    { label: 'kvm-clone',       path: `${PATHS.KVM_SCRIPTS}/kvm-clone.sh` },
    { label: 'kvm-clone-system',path: `${PATHS.KVM_SCRIPTS}/kvm-clone-system.sh` },
    { label: 'fix-nm-connection-vm', path: `${PATHS.KVM_SCRIPTS}/fix-nm-connection-vm.sh` },
  ];

  const missing: string[] = [];
  for (const { label, path } of checks) {
    if (!existsSync(path)) {
      console.warn(`[MCP] Script manquant: ${label} -> ${path}`);
      missing.push(label);
    }
  }

  if (missing.length > 0) {
    logger.warn('path_validation', {
      message: `${missing.length} script(s) manquant(s): ${missing.join(', ')}`,
      params: { missing_tools: missing },
    });
  } else {
    logger.info('path_validation', { message: 'Tous les scripts sont presents' });
  }
}

/**
 * Point d'entrée principal
 */
async function main(): Promise<void> {
  // Créer le répertoire de logs (avec fallback si /var/log non accessible)
  const logDir = ensureLogDir();

  logger.info('server_start', {
    message: 'Starting Fedora Agents MCP Server',
    params: { log_dir: logDir },
  });

  // Valider que tous les scripts référencés sont présents sur le disque
  validatePaths();

  // Créer le transport stdio
  const transport = new StdioServerTransport();

  // Connecter le serveur
  await server.connect(transport);

  logger.info('server_ready', {
    message: `Server ready with ${allTools.length} tools`,
  });
}

// Gestion des erreurs non capturées
process.on('uncaughtException', (error) => {
  logger.error('uncaught_exception', { error: error.message });
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  logger.error('unhandled_rejection', {
    error: reason instanceof Error ? reason.message : String(reason),
  });
  process.exit(1);
});

// Lancer le serveur
main().catch((error) => {
  logger.error('startup_error', { error: error.message });
  process.exit(1);
});
