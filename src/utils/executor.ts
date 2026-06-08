/**
 * Exécuteur de scripts bash avec retry, timeout et gestion d'erreurs
 */

import { spawn } from 'child_process';
import { TIMEOUTS, RETRY_CONFIG, ErrorCode, EXIT_CODE_MAP, TOOL_PERMISSIONS } from '../config.js';
import { logger, generateCorrelationId } from '../logger.js';

export interface ExecuteResult {
  success: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  errorCode: ErrorCode;
  durationMs: number;
  correlationId: string;
}

export interface ExecuteOptions {
  tool: string;
  script: string;
  args: string[];
  timeout?: number;
  /** Timeout en ms fourni par le schéma de l'outil (prioritaire sur config.ts) */
  toolTimeoutMs?: number;
  cwd?: string;
  env?: Record<string, string>;
  /** Callback appelé à chaque ligne CLONE_PROGRESS:XX.XX détectée sur stderr */
  onProgress?: (percent: number) => void;
}

/**
 * Attend un délai (pour backoff)
 */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Codes de sortie qui indiquent une erreur permanente (ne pas retenter)
// 1: erreur générale, 2: mauvais usage/timeout, 126: permission refusée,
// 127: commande introuvable, 130: interrompu par Ctrl+C
const PERMANENT_EXIT_CODES = [1, 2, 126, 127, 130];

// Codes de sortie qui indiquent une erreur transitoire (peut être retentée)
// 124: timeout externe (timeout(1)), 137: process tué (SIGKILL)
const TRANSIENT_EXIT_CODES = [124, 137];

/**
 * Détermine si une erreur justifie un retry.
 * Les erreurs permanentes (permission, commande manquante, etc.) ne doivent pas être retentées.
 */
function shouldRetry(exitCode: number, stderr: string): boolean {
  if (PERMANENT_EXIT_CODES.includes(exitCode)) return false;
  if (stderr.includes('Permission denied') ||
      stderr.includes('not found') ||
      stderr.includes('ENOENT') ||
      stderr.includes('command not found')) {
    return false;
  }
  // Les codes transitoires sont explicitement retentables
  if (TRANSIENT_EXIT_CODES.includes(exitCode)) return true;
  // Par défaut, on retente les codes inconnus
  return true;
}

/**
 * Exécute un script bash une fois
 */
async function executeOnce(options: ExecuteOptions, correlationId: string): Promise<ExecuteResult> {
  const { tool, script, args, timeout, toolTimeoutMs, cwd, env, onProgress } = options;
  // Priorité: toolTimeoutMs (fourni par le schéma outil) > timeout (options.timeout) > config global
  const effectiveTimeout = toolTimeoutMs ?? timeout ?? TIMEOUTS[tool] ?? TIMEOUTS.default;
  const permission = TOOL_PERMISSIONS[tool];

  const startTime = Date.now();

  return new Promise((resolve) => {
    // Construire la commande
    const command = permission?.requiresSudo ? 'sudo' : script;
    const fullArgs = permission?.requiresSudo ? [script, ...args] : args;

    logger.debug('execute_start', {
      tool,
      correlation_id: correlationId,
      message: `Executing: ${command} ${fullArgs.join(' ')}`
    });

    const proc = spawn(command, fullArgs, {
      cwd,
      env: { ...process.env, ...env },
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let killed = false;
    // Buffer partiel pour reconstituer les lignes sur stderr
    let stderrLineBuffer = '';

    // Timeout
    const timeoutHandle = setTimeout(() => {
      killed = true;
      proc.kill('SIGTERM');
      setTimeout(() => {
        if (!proc.killed) {
          proc.kill('SIGKILL');
        }
      }, 5000);
    }, effectiveTimeout);

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    proc.stderr.on('data', (data) => {
      const chunk = data.toString();
      stderr += chunk;

      // Parser les lignes CLONE_PROGRESS si un callback est fourni
      if (onProgress) {
        stderrLineBuffer += chunk;
        const lines = stderrLineBuffer.split('\n');
        // Garder le dernier fragment incomplet dans le buffer
        stderrLineBuffer = lines.pop() ?? '';
        for (const line of lines) {
          const match = line.match(/^CLONE_PROGRESS:(\d+\.?\d*)/);
          if (match) {
            onProgress(parseFloat(match[1]));
          }
        }
      }
    });

    proc.on('close', (code) => {
      clearTimeout(timeoutHandle);
      const durationMs = Date.now() - startTime;

      const exitCode = code ?? (killed ? 2 : 1);
      const errorCode = killed ? ErrorCode.TIMEOUT : (EXIT_CODE_MAP[exitCode] ?? ErrorCode.UNKNOWN_ERROR);

      const result: ExecuteResult = {
        success: exitCode === 0,
        exitCode,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        errorCode,
        durationMs,
        correlationId
      };

      logger.debug('execute_end', {
        tool,
        correlation_id: correlationId,
        duration_ms: durationMs,
        exit_code: exitCode,
        message: killed ? 'Process killed (timeout)' : `Exit code: ${exitCode}`
      });

      resolve(result);
    });

    proc.on('error', (err) => {
      clearTimeout(timeoutHandle);
      const durationMs = Date.now() - startTime;

      resolve({
        success: false,
        exitCode: 1,
        stdout: '',
        stderr: err.message,
        errorCode: ErrorCode.SCRIPT_ERROR,
        durationMs,
        correlationId
      });
    });
  });
}

/**
 * Exécute un script avec retry si applicable
 */
export async function execute(options: ExecuteOptions): Promise<ExecuteResult> {
  const { tool } = options;
  const correlationId = generateCorrelationId();
  const isRetryable = (RETRY_CONFIG.retryable as readonly string[]).includes(tool);

  logger.toolCall(tool, { script: options.script, args: options.args }, correlationId);

  let lastResult: ExecuteResult | null = null;
  const maxAttempts = isRetryable ? RETRY_CONFIG.maxRetries : 1;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (attempt > 0) {
      const backoffMs = RETRY_CONFIG.backoffMs[attempt - 1] ?? RETRY_CONFIG.backoffMs[RETRY_CONFIG.backoffMs.length - 1];
      logger.info('retry_attempt', {
        tool,
        correlation_id: correlationId,
        message: `Retry attempt ${attempt + 1}/${maxAttempts} after ${backoffMs}ms`
      });
      await sleep(backoffMs);
    }

    lastResult = await executeOnce(options, correlationId);

    if (lastResult.success) {
      break;
    }

    // Ne pas retry sur certaines erreurs
    if (lastResult.errorCode === ErrorCode.VALIDATION_ERROR ||
        lastResult.errorCode === ErrorCode.PERMISSION_DENIED) {
      break;
    }

    // Ne pas retry si l'exit code ou le stderr indique une erreur permanente
    if (!shouldRetry(lastResult.exitCode, lastResult.stderr)) {
      logger.debug('retry_skip', {
        tool,
        correlation_id: correlationId,
        message: `Exit code ${lastResult.exitCode} classifié permanent, pas de retry`
      });
      break;
    }
  }

  const result = lastResult!;

  // Log final
  logger.toolResult(
    tool,
    { script: options.script, args: options.args },
    correlationId,
    result.durationMs,
    result.exitCode,
    result.success ? undefined : result.stderr
  );

  // Audit pour les opérations sensibles
  const permission = TOOL_PERMISSIONS[tool];
  if (permission?.dangerous || permission?.requiresSudo) {
    logger.audit({
      tool,
      params: { script: options.script, args: options.args },
      user: process.env.USER ?? 'unknown',
      result: result.success ? 'success' : 'error',
      duration_ms: result.durationMs,
      error: result.success ? undefined : result.stderr,
      exit_code: result.exitCode
    });
  }

  return result;
}

/**
 * Helper pour construire les arguments CLI à partir des paramètres
 */
export function buildArgs(params: Record<string, unknown>): string[] {
  const args: string[] = [];

  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;

    // Convertir camelCase en kebab-case
    const flag = key.replace(/([A-Z])/g, '-$1').toLowerCase();

    if (typeof value === 'boolean') {
      if (value) {
        args.push(`--${flag}`);
      }
    } else if (typeof value === 'string' || typeof value === 'number') {
      args.push(`--${flag}=${value}`);
    }
  }

  return args;
}
