import type { ClipV1, ParsedFileName, ProjectV1, Rational } from "./types";

export const OUTPUT_FPS: Rational = { numerator: 60000, denominator: 1001 };
export const TRANSITION_SECONDS = 0.5;

export function centeredCropForAspect(width: number, height: number, aspect = 16 / 9) {
  if (width <= 0 || height <= 0 || !Number.isFinite(aspect) || aspect <= 0) {
    return { x: 0, y: 0, width: 1, height: 1 };
  }
  const sourceAspect = width / height;
  if (sourceAspect > aspect) {
    const cropWidth = aspect / sourceAspect;
    return { x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1 };
  }
  const cropHeight = sourceAspect / aspect;
  return { x: 0, y: (1 - cropHeight) / 2, width: 1, height: cropHeight };
}

export function parseVideoFileName(fileName: string): ParsedFileName | null {
  const stem = fileName.replace(/\.[^.]+$/, "");
  const separator = stem.indexOf("_");
  if (separator <= 0 || separator === stem.length - 1) return null;
  const orderText = stem.slice(0, separator);
  const bandName = stem.slice(separator + 1).trim();
  if (!/^\d+$/.test(orderText) || !bandName) return null;
  const order = Number(orderText);
  if (!Number.isSafeInteger(order) || order < 1) return null;
  return { order, bandName };
}

export function sortClipsByOrder<T extends Pick<ClipV1, "order" | "bandName">>(clips: T[]): T[] {
  return [...clips].sort((a, b) => a.order - b.order || a.bandName.localeCompare(b.bandName, "ja"));
}

export function duplicateOrders(clips: Array<Pick<ClipV1, "order"> & Partial<Pick<ClipV1, "joinWithPrevious">>>): Set<number> {
  const counts = new Map<number, number>();
  clips.forEach((clip, index) => {
    if (index > 0 && clip.joinWithPrevious) return;
    counts.set(clip.order, (counts.get(clip.order) ?? 0) + 1);
  });
  return new Set([...counts.entries()].filter(([, count]) => count > 1).map(([order]) => order));
}

export function clipGroups(clips: ClipV1[]): ClipV1[][] {
  const groups: ClipV1[][] = [];
  clips.forEach((clip, index) => {
    if (index === 0 || !clip.joinWithPrevious) groups.push([clip]);
    else groups[groups.length - 1].push(clip);
  });
  return groups;
}

export function bandCount(clips: ClipV1[]): number {
  return clipGroups(clips).length;
}

export function renumberClipOrders(clips: ClipV1[]): ClipV1[] {
  let order = 0;
  return clips.map((clip, index) => {
    const joinWithPrevious = index > 0 && Boolean(clip.joinWithPrevious);
    if (!joinWithPrevious) order += 1;
    return { ...clip, order, joinWithPrevious };
  });
}

export function moveClipGroup(clips: ClipV1[], sourceId: string, targetId: string): ClipV1[] {
  const groups = clipGroups(clips);
  const sourceIndex = groups.findIndex((group) => group.some((clip) => clip.id === sourceId));
  const targetIndex = groups.findIndex((group) => group.some((clip) => clip.id === targetId));
  if (sourceIndex < 0 || targetIndex < 0 || sourceIndex === targetIndex) return clips;
  const [moving] = groups.splice(sourceIndex, 1);
  groups.splice(targetIndex, 0, moving);
  return renumberClipOrders(groups.flat());
}

export function fpsValue(fps: Rational): number {
  if (fps.denominator === 0) return 0;
  return fps.numerator / fps.denominator;
}

export function frameToSeconds(frame: number, fps: Rational): number {
  const value = fpsValue(fps);
  return value > 0 ? frame / value : 0;
}

export function secondsToFrame(seconds: number, fps: Rational): number {
  return Math.max(0, Math.round(seconds * fpsValue(fps)));
}

export function clipDurationSeconds(clip: ClipV1): number {
  return Math.max(0, frameToSeconds(clip.outFrameExclusive - clip.inFrame, clip.media.fps));
}

export function projectDurationSeconds(clips: ClipV1[]): number {
  if (clips.length === 0) return 0;
  const total = clips.reduce((sum, clip) => sum + clipDurationSeconds(clip), 0);
  const transitions = clips.slice(1).filter((clip) => !clip.joinWithPrevious).length;
  return Math.max(0, total - TRANSITION_SECONDS * transitions);
}

export function chapterRows(clips: ClipV1[]): Array<{ seconds: number; text: string }> {
  let cursor = 0;
  const rows: Array<{ seconds: number; text: string }> = [];
  clips.forEach((clip, index) => {
    if (index === 0 || !clip.joinWithPrevious) {
      rows.push({ seconds: Math.max(0, Math.floor(cursor)), text: clip.bandName });
    }
    cursor += clipDurationSeconds(clip);
    if (index < clips.length - 1 && !clips[index + 1].joinWithPrevious) cursor -= TRANSITION_SECONDS;
  });
  return rows;
}

export function formatChapterTime(totalSeconds: number): string {
  const value = Math.max(0, Math.floor(totalSeconds));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const seconds = value % 60;
  return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export function formatClock(totalSeconds: number): string {
  if (!Number.isFinite(totalSeconds)) return "0:00:00.000";
  const value = Math.max(0, totalSeconds);
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const seconds = Math.floor(value % 60);
  const milliseconds = Math.floor((value - Math.floor(value)) * 1000);
  return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}.${String(milliseconds).padStart(3, "0")}`;
}

export function parseClock(value: string): number | null {
  const match = value.trim().match(/^(\d+):([0-5]?\d):([0-5]?\d)(?:\.(\d{1,3}))?$/);
  if (!match) return null;
  const milliseconds = match[4] ? Number(match[4].padEnd(3, "0")) : 0;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) + milliseconds / 1000;
}

export function estimateOutputBytes(durationSeconds: number, resolution: "1080p" | "1440p"): number {
  const videoMbps = resolution === "1080p" ? 15 : 30;
  const totalMbps = videoMbps + 0.384;
  return (durationSeconds * totalMbps * 1_000_000) / 8;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes.toFixed(0)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[index]}`;
}

export function chapterWarnings(clips: ClipV1[]): string[] {
  const warnings: string[] = [];
  const groups = clipGroups(clips);
  if (groups.length > 0 && groups.length < 3) warnings.push("YouTubeのチャプター表示には3件以上の時刻が必要です。");
  groups.forEach((group) => {
    const duration = group.reduce((sum, clip) => sum + clipDurationSeconds(clip), 0);
    if (duration < 10) {
      warnings.push(`${group[0].bandName}は10秒未満のため，YouTubeでチャプターとして認識されない可能性があります。`);
    }
  });
  return warnings;
}

export function validateProject(value: unknown): value is ProjectV1 {
  if (!value || typeof value !== "object") return false;
  const project = value as Partial<ProjectV1>;
  return (
    project.schemaVersion === 1 &&
    (project.appVersion === "0.1.0" || project.appVersion === "0.2.0" || project.appVersion === "0.2.1") &&
    typeof project.eventName === "string" &&
    Array.isArray(project.clips) &&
    (project.outputResolution === "1080p" || project.outputResolution === "1440p") &&
    project.transitionMs === 500
  );
}

export function basename(path: string): string {
  return path.replace(/\\/g, "/").split("/").pop() ?? path;
}

export function parentFolderName(path: string): string {
  const pieces = path.replace(/\\/g, "/").split("/").filter(Boolean);
  return pieces.length >= 2 ? pieces[pieces.length - 2] : "ライブ動画";
}
