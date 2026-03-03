import { closeMainWindow, LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { parseJsonOrNull, runSdImport } from "./sd-import-lib";

type Arguments = {
  location?: string;
};

type AutoResponse = {
  summary?: {
    volume_name?: string;
    new_files?: number;
    known_files?: number;
    conflict_files?: number;
  };
  action?: string;
};

export default async function Command(props: LaunchProps<{ arguments: Arguments }>) {
  await closeMainWindow({ clearRootSearch: true });
  const toast = await showToast({ style: Toast.Style.Animated, title: "Running SD import" });

  try {
    const args = ["auto"];
    const location = props.arguments.location?.trim();
    if (location) {
      args.push(location);
    }

    const { stdout } = await runSdImport(args);
    const parsed = parseJsonOrNull<AutoResponse>(stdout);

    toast.style = Toast.Style.Success;
    if (parsed?.summary) {
      const s = parsed.summary;
      toast.title = `SD import: ${s.new_files ?? 0} new, ${s.known_files ?? 0} known, ${s.conflict_files ?? 0} conflicts`;
      toast.message = s.volume_name ?? "";
    } else {
      toast.title = "SD import finished";
      toast.message = stdout.trim().split("\n")[0] ?? "";
    }
    await showHUD(toast.title);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "SD import failed";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
