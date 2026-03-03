import { closeMainWindow, showHUD, showToast, Toast } from "@raycast/api";
import { parseJsonOrNull, runSdImport } from "./sd-import-lib";

type RetryResponse = {
  job_id: string;
  imported_files: number;
  skipped_files: number;
  failed_files: number;
};

export default async function Command() {
  await closeMainWindow({ clearRootSearch: true });
  const toast = await showToast({ style: Toast.Style.Animated, title: "Retrying latest SD job" });

  try {
    const { stdout } = await runSdImport(["retry-latest"]);
    const parsed = parseJsonOrNull<RetryResponse>(stdout);

    toast.style = Toast.Style.Success;
    if (parsed) {
      toast.title = `Retried ${parsed.job_id}`;
      toast.message = `${parsed.imported_files} imported, ${parsed.skipped_files} skipped, ${parsed.failed_files} failed`;
      await showHUD(toast.message);
    } else {
      toast.title = "Retry completed";
      toast.message = stdout.trim().split("\n")[0] ?? "";
      await showHUD(toast.title);
    }
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Retry failed";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
