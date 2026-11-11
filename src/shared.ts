import type { ProjectV1 } from "./types";
import { clipGroups, isBlockingImportError } from "./utils";

export type Step = "import" | "trim" | "thumbnail" | "export";

export const isMac = typeof navigator !== "undefined" && /Mac/i.test(navigator.userAgent);
/** ショートカット表示用の修飾キー名 */
export const MOD = isMac ? "⌘" : "Ctrl+";

export function errorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

export function safeEventName(value: string): string {
  return value.trim().replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/, "") || "ライブ動画";
}

export interface Issue {
  step: Step;
  text: string;
}

/** 書き出し前に直す必要がある問題。手順タブのバッジと書き出し画面で使う。 */
export function projectIssues(project: ProjectV1, outputDirectory: string): Issue[] {
  const issues: Issue[] = [];
  if (project.clips.length === 0) {
    issues.push({ step: "import", text: "動画が追加されていません" });
  }
  const groups = clipGroups(project.clips);
  project.clips.forEach((clip) => {
    const band = groups.find((group) => group.includes(clip))?.[0].bandName || clip.sourceFileName;
    if (isBlockingImportError(clip)) {
      issues.push({ step: "import", text: `${band}：${clip.importError}` });
    } else if (!clip.media.hasAudio) {
      issues.push({ step: "import", text: `${band}：音声が入っていない動画は使えません` });
    }
  });
  groups.forEach((group) => {
    if (!group[0].bandName.trim()) issues.push({ step: "import", text: `${group[0].sourceFileName}：バンド名が空です` });
  });
  if (!project.eventName.trim()) issues.push({ step: "export", text: "ファイル名（イベント名）が空です" });
  if (!outputDirectory) issues.push({ step: "export", text: "保存先が決まっていません" });
  return issues;
}

export async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    // WebViewによってはClipboard APIが使えないため，選択してコピーする。
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  const ok = document.execCommand("copy");
  area.remove();
  if (!ok) throw new Error("コピーできませんでした。");
}

/** 入力欄で打鍵中か（ショートカットを横取りしないため） */
export function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  if (target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement) return true;
  if (target instanceof HTMLInputElement) {
    return !["range", "checkbox", "radio", "button"].includes(target.type);
  }
  return false;
}
