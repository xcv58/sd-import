import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  Toast,
  showToast,
  confirmAlert,
  Alert,
  open,
} from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import { Job, parseJsonOrNull, runSdImport } from "./sd-import-lib";

export default function Command() {
  const [jobs, setJobs] = useState<Job[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string>("");

  async function loadJobs() {
    setIsLoading(true);
    setError("");
    try {
      const { stdout } = await runSdImport(["list-jobs", "--json", "--limit", "50"]);
      const parsed = parseJsonOrNull<Job[]>(stdout);
      if (!parsed) {
        throw new Error("Failed to parse jobs JSON");
      }
      setJobs(parsed);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    loadJobs();
  }, []);

  const emptyDescription = useMemo(() => {
    if (error) {
      return error;
    }
    return "No jobs yet";
  }, [error]);

  async function runJobAction(args: string[], successTitle: string) {
    const toast = await showToast({ style: Toast.Style.Animated, title: "Running command" });
    try {
      const { stdout } = await runSdImport(args);
      toast.style = Toast.Style.Success;
      toast.title = successTitle;
      toast.message = stdout.trim().split("\n")[0] ?? "";
      await loadJobs();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Command failed";
      toast.message = e instanceof Error ? e.message : String(e);
    }
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search jobs" isShowingDetail={false}>
      {jobs.length === 0 ? <List.EmptyView title="No Jobs" description={emptyDescription} /> : null}
      {jobs.map((job) => {
        const accessories: List.Item.Accessory[] = [
          { text: `status ${job.status}` },
          { text: `new ${job.new_files}` },
          { text: `known ${job.known_files}` },
        ];

        if (job.conflict_files > 0) {
          accessories.push({ text: `conflicts ${job.conflict_files}`, icon: { source: Icon.ExclamationMark, tintColor: Color.Orange } });
        }
        if (job.failed_files > 0) {
          accessories.push({ text: `failed ${job.failed_files}`, icon: { source: Icon.XMarkCircle, tintColor: Color.Red } });
        }

        return (
          <List.Item
            key={job.job_id}
            title={job.job_id}
            subtitle={`${job.volume_name ?? "volume"} | ${job.created_at}`}
            accessories={accessories}
            actions={
              <ActionPanel>
                <Action
                  title="Import Job"
                  icon={Icon.Download}
                  onAction={async () => {
                    const ok = await confirmAlert({
                      title: "Import this job?",
                      message: `Run import for ${job.job_id}`,
                      primaryAction: {
                        style: Alert.ActionStyle.Default,
                        title: "Import",
                      },
                    });
                    if (!ok) {
                      return;
                    }
                    await runJobAction(["import", "--job-id", job.job_id], `Imported ${job.job_id}`);
                  }}
                />
                <Action
                  title="Retry Job"
                  icon={Icon.Repeat}
                  onAction={() => runJobAction(["retry", "--job-id", job.job_id], `Retried ${job.job_id}`)}
                />
                <Action
                  title="Run Auto Import"
                  icon={Icon.Play}
                  onAction={() => runJobAction(["auto"], "Auto import finished")}
                />
                {job.report_path ? (
                  <Action title="Open Report" icon={Icon.Document} onAction={() => open(job.report_path as string)} />
                ) : null}
                <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={loadJobs} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
