import { getPreferenceValues } from "@raycast/api";
import { execFile } from "node:child_process";
import fs from "node:fs";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

type Preferences = {
  launcherPath: string;
};

export type Job = {
  job_id: string;
  created_at: string;
  mount_path: string;
  volume_name?: string | null;
  status: string;
  scanned_files: number;
  new_files: number;
  known_files: number;
  conflict_files: number;
  imported_files: number;
  failed_files: number;
  report_path?: string | null;
};

export type RemovableMount = {
  mount_path: string;
  volume_name?: string | null;
  volume_uuid?: string | null;
  mounted_at?: number;
  mounted_at_iso?: string;
};

export async function runSdImport(args: string[]) {
  const prefs = getPreferenceValues<Preferences>();
  const launcherPath = prefs.launcherPath;

  if (!launcherPath) {
    throw new Error("Preference launcherPath is empty");
  }
  if (!fs.existsSync(launcherPath)) {
    throw new Error(`sd-import not found at ${launcherPath}`);
  }

  return execFileAsync(launcherPath, args, {
    maxBuffer: 10 * 1024 * 1024,
  });
}

export function parseJsonOrNull<T>(text: string): T | null {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
    return null;
  }
  try {
    return JSON.parse(trimmed) as T;
  } catch {
    return null;
  }
}
