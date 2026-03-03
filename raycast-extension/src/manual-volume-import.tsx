import {
  Action,
  ActionPanel,
  Alert,
  Color,
  confirmAlert,
  Icon,
  LaunchProps,
  List,
  Toast,
  open,
  showHUD,
  showToast,
} from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import { parseJsonOrNull, RemovableMount, runSdImport } from "./sd-import-lib";

type Arguments = {
  location?: string;
};

type RunResponse = {
  summary?: {
    volume_name?: string;
    new_files?: number;
    known_files?: number;
    conflict_files?: number;
  };
  action?: string;
};

export default function Command(props: LaunchProps<{ arguments: Arguments }>) {
  const [mounts, setMounts] = useState<RemovableMount[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string>("");

  const location = props.arguments.location?.trim();

  async function loadMounts() {
    setIsLoading(true);
    setError("");
    try {
      const { stdout } = await runSdImport(["list-mounts", "--json"]);
      const parsed = parseJsonOrNull<RemovableMount[]>(stdout);
      if (!parsed) {
        throw new Error("Failed to parse mounted volumes JSON");
      }
      setMounts(parsed);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    loadMounts();
  }, []);

  const emptyDescription = useMemo(() => {
    if (error) {
      return error;
    }
    return "No removable mounted volumes found";
  }, [error]);

  async function runForMount(mount: RemovableMount, mode: "run" | "scan") {
    const toast = await showToast({ style: Toast.Style.Animated, title: "Running command" });
    try {
      const args: string[] = [mode, "--input", mount.mount_path];
      if (location) {
        args.push("--location", location);
      }
      if (mode === "run") {
        args.push("--notify");
      }

      const { stdout } = await runSdImport(args);
      const parsed = parseJsonOrNull<RunResponse>(stdout);

      toast.style = Toast.Style.Success;
      if (parsed?.summary) {
        const s = parsed.summary;
        toast.title = `${mount.volume_name ?? mount.mount_path}: ${s.new_files ?? 0} new, ${s.known_files ?? 0} known, ${s.conflict_files ?? 0} conflicts`;
        await showHUD(toast.title);
      } else {
        toast.title = mode === "run" ? "Volume import triggered" : "Volume scan completed";
        toast.message = stdout.trim().split("\n")[0] ?? "";
        await showHUD(toast.title);
      }
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Command failed";
      toast.message = e instanceof Error ? e.message : String(e);
    }
  }

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Select mounted SD/removable volume"
      isShowingDetail={false}
      navigationTitle="SD Import: Select Volume"
    >
      {mounts.length === 0 ? <List.EmptyView title="No Volumes" description={emptyDescription} /> : null}
      {mounts.map((mount) => (
        <List.Item
          key={mount.mount_path}
          icon={Icon.HardDrive}
          title={mount.volume_name || mount.mount_path}
          subtitle={mount.mount_path}
          accessories={[
            ...(mount.mounted_at_iso ? [{ text: mount.mounted_at_iso }] : []),
            ...(mount.volume_uuid ? [{ text: mount.volume_uuid, icon: { source: Icon.Key, tintColor: Color.SecondaryText } }] : []),
          ]}
          actions={
            <ActionPanel>
              <Action
                title="Run Interactive Import"
                icon={Icon.Play}
                onAction={async () => {
                  const ok = await confirmAlert({
                    title: "Start import for selected volume?",
                    message: mount.mount_path,
                    primaryAction: { style: Alert.ActionStyle.Default, title: "Start" },
                  });
                  if (!ok) {
                    return;
                  }
                  await runForMount(mount, "run");
                }}
              />
              <Action title="Scan Only" icon={Icon.MagnifyingGlass} onAction={() => runForMount(mount, "scan")} />
              <Action title="Open Volume in Finder" icon={Icon.Folder} onAction={() => open(mount.mount_path)} />
              <Action title="Refresh Volumes" icon={Icon.ArrowClockwise} onAction={loadMounts} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
