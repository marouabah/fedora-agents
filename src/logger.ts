/**
 * Logger structuré avec support audit
 */

import { createWriteStream, existsSync, mkdirSync } from 'fs';
import { PATHS } from './config.js';

// Niveaux de log
export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

// Structure d'une entrée de log
export interface LogEntry {
  timestamp: string;
  level: LogLevel;
  event: string;
  message?: string;
  tool?: string;
  params?: Record<string, unknown>;
  correlation_id?: string;
  duration_ms?: number;
  error?: string;
  exit_code?: number;
}

// Structure d'une entrée d'audit
export interface AuditEntry {
  timestamp: string;
  tool: string;
  params: Record<string, unknown>;
  user: string;
  result: 'success' | 'error';
  duration_ms: number;
  error?: string;
  exit_code?: number;
}

// Générateur de correlation ID
export function generateCorrelationId(): string {
  return `${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
}

class Logger {
  private logStream: ReturnType<typeof createWriteStream> | null = null;
  private auditStream: ReturnType<typeof createWriteStream> | null = null;
  private errorStream: ReturnType<typeof createWriteStream> | null = null;
  private initialized = false;

  constructor() {
    this.init();
  }

  private init(): void {
    if (this.initialized) return;

    try {
      // Créer le répertoire de logs si nécessaire
      if (!existsSync(PATHS.LOG_DIR)) {
        mkdirSync(PATHS.LOG_DIR, { recursive: true, mode: 0o755 });
      }

      // Ouvrir les fichiers de log
      const date = new Date().toISOString().split('T')[0];
      this.logStream = createWriteStream(`${PATHS.LOG_DIR}/server-${date}.log`, { flags: 'a' });
      this.auditStream = createWriteStream(`${PATHS.LOG_DIR}/audit-${date}.log`, { flags: 'a' });
      this.errorStream = createWriteStream(`${PATHS.LOG_DIR}/error-${date}.log`, { flags: 'a' });

      this.initialized = true;
    } catch {
      // Si on ne peut pas écrire dans /var/log, on continue sans fichiers
      console.error('[Logger] Cannot write to log directory, logging to stderr only');
    }
  }

  private formatEntry(entry: LogEntry): string {
    return JSON.stringify(entry);
  }

  private write(entry: LogEntry): void {
    const line = this.formatEntry(entry) + '\n';

    // Toujours écrire sur stderr (pour debug)
    if (entry.level === 'error') {
      process.stderr.write(line);
    }

    // Écrire dans les fichiers si disponibles
    if (this.logStream) {
      this.logStream.write(line);
    }

    if (entry.level === 'error' && this.errorStream) {
      this.errorStream.write(line);
    }
  }

  private log(level: LogLevel, event: string, data?: Partial<LogEntry>): void {
    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      event,
      ...data
    };
    this.write(entry);
  }

  debug(event: string, data?: Partial<LogEntry>): void {
    this.log('debug', event, data);
  }

  info(event: string, data?: Partial<LogEntry>): void {
    this.log('info', event, data);
  }

  warn(event: string, data?: Partial<LogEntry>): void {
    this.log('warn', event, data);
  }

  error(event: string, data?: Partial<LogEntry>): void {
    this.log('error', event, data);
  }

  // Log spécifique pour les appels d'outils
  toolCall(tool: string, params: Record<string, unknown>, correlationId: string): void {
    this.info('tool_call_start', {
      tool,
      params,
      correlation_id: correlationId
    });
  }

  toolResult(
    tool: string,
    params: Record<string, unknown>,
    correlationId: string,
    durationMs: number,
    exitCode: number,
    error?: string
  ): void {
    const level = exitCode === 0 ? 'info' : 'error';
    this.log(level, 'tool_call_end', {
      tool,
      params,
      correlation_id: correlationId,
      duration_ms: durationMs,
      exit_code: exitCode,
      error
    });
  }

  // Audit des opérations sensibles
  audit(entry: Omit<AuditEntry, 'timestamp'>): void {
    const auditEntry: AuditEntry = {
      timestamp: new Date().toISOString(),
      ...entry
    };

    const line = JSON.stringify(auditEntry) + '\n';

    if (this.auditStream) {
      this.auditStream.write(line);
    }

    // Aussi logger normalement
    this.info('audit', {
      tool: entry.tool,
      params: entry.params,
      duration_ms: entry.duration_ms,
      error: entry.error
    });
  }

  // Fermer proprement les streams
  close(): void {
    this.logStream?.end();
    this.auditStream?.end();
    this.errorStream?.end();
  }
}

// Instance singleton
export const logger = new Logger();

// Cleanup à la fermeture
process.on('beforeExit', () => {
  logger.close();
});
