#!/usr/bin/env bun

/**
 * Transcript reading and path resolution
 *
 * Provides:
 * - Transcript path resolution (session ID -> file path)
 * - Exchange counting (conversation depth)
 */

import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { getClaudeSessionId } from "./session";

/**
 * Convert a directory path to Claude Code's project slug format.
 * Slug = PWD with `/` and `_` replaced by `-`
 */
function pathToSlug(path: string): string {
  return path.replace(/[/_]/g, "-");
}

/**
 * Find the most recently modified .jsonl transcript in a project directory.
 * Fallback for when getClaudeSessionId() can't resolve the current session.
 */
function findMostRecentTranscript(projectDir: string): string | null {
  try {
    if (!existsSync(projectDir)) return null;
    const files = readdirSync(projectDir)
      .filter((f) => f.endsWith(".jsonl"))
      .filter((f) => !f.includes("agent-"))
      .map((f) => {
        const full = join(projectDir, f);
        return { path: full, mtime: statSync(full).mtimeMs };
      })
      .sort((a, b) => b.mtime - a.mtime);
    return files.length > 0 ? files[0].path : null;
  } catch {
    return null;
  }
}

/**
 * Get the transcript file path for a Claude Code session.
 *
 * Resolution order:
 * 1. Explicit sessionId parameter
 * 2. getClaudeSessionId() (from env var)
 * 3. Most recently modified .jsonl in project dir (fallback)
 */
export function getTranscriptPath(sessionId?: string): string | null {
  const home = process.env.HOME;
  if (!home) return null;

  const cwd = process.env.PWD || process.cwd();
  const slug = pathToSlug(cwd);
  const projectDir = join(home, ".claude", "projects", slug);

  // Try explicit session or env var
  const session = sessionId ?? getClaudeSessionId();
  if (session) {
    const transcriptPath = join(projectDir, `${session}.jsonl`);
    if (existsSync(transcriptPath)) return transcriptPath;
    // Session ID known but transcript doesn't exist yet — don't fall back
    // to stale transcript which could cause state mutations on wrong session.
    return null;
  }

  // Fallback: no session ID at all — best effort via most recent transcript
  return findMostRecentTranscript(projectDir);
}

/**
 * Count user exchanges in a transcript file.
 *
 * Claude Code transcript is JSONL format.
 * We count 'user' messages (excluding toolUseResult) as proxy for depth.
 */
export async function countExchanges(transcriptPath: string): Promise<number> {
  try {
    const file = Bun.file(transcriptPath);
    if (!(await file.exists())) return 0;

    const content = await file.text();
    const lines = content.trim().split("\n").filter(Boolean);

    let count = 0;
    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        // Count only actual human messages, not tool results
        if (entry.type === "user" && !entry.toolUseResult) count++;
      } catch {
        // Skip malformed lines
      }
    }
    return count;
  } catch {
    return 0;
  }
}
