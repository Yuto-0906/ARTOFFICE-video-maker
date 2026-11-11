import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open, save } from "@tauri-apps/plugin-dialog";
import type { Area } from "react-easy-crop";
import type {
  ClipV1,
  OutputPaths,
  PreparedThumbnail,
  ProbeResult,
  ProjectV1,
  RenderFinished,
  RenderProgress,
  RenderRequest,
  RenderStarted,
  ThumbnailV1,
  ToolStatus,
} from "./types";
import {
  basename,
  centeredCropForAspect,
  clipGroups,
  guessOrderAndBandName,
  isThumbnailImagePath,
  isVideoPath,
  moveClipGroup,
  parentDirectory,
  parentFolderName,
  renumberClipOrders,
  sortClipsByOrder,
  THUMBNAIL_EXTENSIONS,
  validateProject,
  VIDEO_EXTENSIONS,
} from "./utils";
import { errorMessage, isMac, MOD, projectIssues, safeEventName, type Step } from "./shared";
import { RedoIcon, UndoIcon } from "./icons";
import logoUrl from "./assets/logo.png";
import ImportStep from "./steps/ImportStep";
import TrimStep from "./steps/TrimStep";
import ThumbnailStep from "./steps/ThumbnailStep";
import ExportStep from "./steps/ExportStep";

const EMPTY_PROJECT: ProjectV1 = {
  schemaVersion: 1,
  appVersion: "0.4.0",
  eventName: "",
  clips: [],
  outputResolution: "source",
  outputFrameRate: "source",
  transitionMs: 500,
  thumbnail: null,
};

const STEPS: Array<{ id: Step; label: string }> = [
  { id: "import", label: "動画" },
  { id: "trim", label: "カット" },
  { id: "thumbnail", label: "サムネイル" },
  { id: "export", label: "書き出し" },
];

const PROJECT_FILTER = [{ name: "ARTOFFICE動画プロジェクト", extensions: ["aovproj"] }];
/** この間隔内に同じ種類の変更が続いた場合は，元に戻す単位を1つにまとめる */
const HISTORY_MERGE_MS = 800;
const AUTOSAVE_DELAY_MS = 1500;

interface Toast {
  id: number;
  text: string;
  action?: { label: string; run: () => void };
}

interface Confirmation {
  title: string;
  body: string;
  confirmLabel: string;
  danger?: boolean;
  onConfirm: () => void;
}

type SaveState = "idle" | "saving" | "error";

export default function App() {
  const [project, setProjectState] = useState<ProjectV1>(EMPTY_PROJECT);
  const projectRef = useRef(project);
  const history = useRef<{ past: ProjectV1[]; future: ProjectV1[]; lastKey?: string; lastAt: number }>({ past: [], future: [], lastAt: 0 });
  const [historySize, setHistorySize] = useState({ past: 0, future: 0 });
  const [projectPath, setProjectPath] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const [step, setStep] = useState<Step>("import");
  const [selectedClipId, setSelectedClipId] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [toolStatus, setToolStatus] = useState<ToolStatus | null>(null);
  const [renderJobId, setRenderJobId] = useState<string | null>(null);
  const [renderProgress, setRenderProgress] = useState<RenderProgress | null>(null);
  const [renderResult, setRenderResult] = useState<RenderFinished | null>(null);
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [closeRequested, setCloseRequested] = useState(false);
  const [closing, setClosing] = useState(false);
  const [fileDragActive, setFileDragActive] = useState(false);

  const selectedClip = project.clips.find((clip) => clip.id === selectedClipId) ?? project.clips[0] ?? null;
  const outputDirectory = project.outputDirectory ?? (project.clips[0] ? parentDirectory(project.clips[0].sourcePath) : "");
  const issues = useMemo(() => projectIssues(project, outputDirectory), [project, outputDirectory]);

  // ---- プロジェクトの状態と元に戻す ----

  const syncHistorySize = () => setHistorySize({ past: history.current.past.length, future: history.current.future.length });

  const replaceProject = useCallback((next: ProjectV1, options: { resetHistory?: boolean } = {}) => {
    projectRef.current = next;
    setProjectState(next);
    if (options.resetHistory) {
      history.current = { past: [], future: [], lastAt: 0 };
      syncHistorySize();
    }
  }, []);

  /** key が同じ変更は短時間ならまとめて1回の「元に戻す」で戻る */
  const updateProject = useCallback((updater: (current: ProjectV1) => ProjectV1, key?: string) => {
    const current = projectRef.current;
    const next = updater(current);
    if (next === current) return;
    const h = history.current;
    const now = Date.now();
    if (!(key && h.lastKey === key && now - h.lastAt < HISTORY_MERGE_MS)) {
      h.past.push(current);
      if (h.past.length > 200) h.past.shift();
    }
    h.lastKey = key;
    h.lastAt = now;
    h.future = [];
    syncHistorySize();
    projectRef.current = next;
    setProjectState(next);
    setDirty(true);
  }, []);

  const undo = useCallback(() => {
    const h = history.current;
    const previous = h.past.pop();
    if (!previous) return;
    h.future.push(projectRef.current);
    h.lastKey = undefined;
    syncHistorySize();
    projectRef.current = previous;
    setProjectState(previous);
    setDirty(true);
  }, []);

  const redo = useCallback(() => {
    const h = history.current;
    const next = h.future.pop();
    if (!next) return;
    h.past.push(projectRef.current);
    h.lastKey = undefined;
    syncHistorySize();
    projectRef.current = next;
    setProjectState(next);
    setDirty(true);
  }, []);

  const showToast = useCallback((text: string, action?: Toast["action"]) => {
    const id = Date.now() + Math.random();
    setToasts((current) => [...current.slice(-2), { id, text, action }]);
    setTimeout(() => setToasts((current) => current.filter((toast) => toast.id !== id)), action ? 7000 : 3500);
  }, []);

  // ---- 起動時・書き出しイベント ----

  useEffect(() => {
    invoke<ToolStatus>("tool_status")
      .then(async (status) => {
        setToolStatus(status);
        if (status.fontPath) {
          try {
            const font = new FontFace("AOV Noto Sans JP", `url(${convertFileSrc(status.fontPath)})`, { weight: "900" });
            await font.load();
            document.fonts.add(font);
          } catch {
            // 読み込めない場合はシステムの日本語フォントで表示する。
          }
        }
      })
      .catch((reason) => setError(errorMessage(reason)));
  }, []);

  useEffect(() => {
    const unlistenProgress = listen<RenderProgress>("render-progress", ({ payload }) => {
      setRenderProgress((current) => (current?.jobId && current.jobId !== payload.jobId ? current : payload));
    });
    const unlistenFinished = listen<RenderFinished>("render-finished", ({ payload }) => {
      setRenderJobId((current) => (current === payload.jobId ? null : current));
      setRenderResult(payload);
      if (payload.status === "completed") showToast("書き出しました");
      else if (payload.status === "failed") setError(payload.error ?? "書き出しに失敗しました。");
      else showToast("書き出しを中止しました");
    });
    return () => {
      void unlistenProgress.then((unlisten) => unlisten());
      void unlistenFinished.then((unlisten) => unlisten());
    };
  }, [showToast]);

  useEffect(() => {
    if (project.clips.length === 0) setSelectedClipId(null);
    else if (!project.clips.some((clip) => clip.id === selectedClipId)) setSelectedClipId(project.clips[0].id);
  }, [project.clips, selectedClipId]);

  // ---- 保存 ----

  const saveProject = useCallback(async (saveAs = false): Promise<boolean> => {
    try {
      let destination = saveAs ? null : projectPath;
      if (!destination) {
        destination = await save({ defaultPath: `${safeEventName(projectRef.current.eventName)}.aovproj`, filters: PROJECT_FILTER });
      }
      if (!destination) return false;
      if (!destination.toLocaleLowerCase().endsWith(".aovproj")) destination += ".aovproj";
      const snapshot = projectRef.current;
      setSaveState("saving");
      await invoke("write_project", { path: destination, project: snapshot });
      setProjectPath(destination);
      setSaveState("idle");
      // 保存中に編集が続いた場合は未保存のままにする。
      if (projectRef.current === snapshot) setDirty(false);
      return true;
    } catch (reason) {
      setSaveState("error");
      setError(`保存できませんでした。\n${errorMessage(reason)}`);
      return false;
    }
  }, [projectPath]);

  // 一度保存したプロジェクトは自動で上書き保存する。
  useEffect(() => {
    if (!dirty || !projectPath || closing || saveState === "error") return;
    const timer = setTimeout(() => void saveProject(false), AUTOSAVE_DELAY_MS);
    return () => clearTimeout(timer);
  }, [project, dirty, projectPath, closing, saveState, saveProject]);

  // ---- 読込 ----

  async function refreshProjectMedia(loaded: ProjectV1): Promise<ProjectV1> {
    if (loaded.clips.length === 0) return loaded;
    const results = await invoke<ProbeResult[]>("probe_media", { paths: loaded.clips.map((clip) => clip.sourcePath) });
    const byPath = new Map(results.map((result) => [result.path.toLocaleLowerCase(), result]));
    return {
      ...loaded,
      clips: loaded.clips.map((clip) => {
        const current = byPath.get(clip.sourcePath.toLocaleLowerCase());
        if (!current?.media) return { ...clip, importError: current?.error ?? "元動画が見つかりません" };
        const inFrame = Math.min(clip.inFrame, Math.max(0, current.media.frameCount - 1));
        const outFrameExclusive = Math.max(inFrame + 1, Math.min(clip.outFrameExclusive, current.media.frameCount));
        return { ...clip, media: current.media, fingerprint: current.fingerprint, inFrame, outFrameExclusive, importError: undefined };
      }),
    };
  }

  const addVideoPaths = useCallback(async (paths: string[]) => {
    if (paths.length === 0) return;
    setBusy(`動画を確認しています（${paths.length}本）`);
    setError(null);
    try {
      const results = await invoke<ProbeResult[]>("probe_media", { paths });
      const current = projectRef.current;
      const existing = new Set(current.clips.map((clip) => clip.sourcePath.toLocaleLowerCase()));
      const failures: string[] = [];
      const imported: ClipV1[] = [];
      let skipped = 0;
      // 番号の無い動画は，番号付きの動画（今回追加する分も含む）の後ろに並べる。
      const guessedOrders = results.map((result) => guessOrderAndBandName(result.fileName).order ?? 0);
      let fallbackOrder = Math.max(0, ...current.clips.map((clip) => clip.order), ...guessedOrders) + 1;

      results.forEach((result) => {
        if (existing.has(result.path.toLocaleLowerCase())) {
          skipped += 1;
          return;
        }
        if (!result.media) {
          failures.push(`${result.fileName}：${result.error ?? "動画として読み込めませんでした"}`);
          return;
        }
        const guessed = guessOrderAndBandName(result.fileName);
        imported.push({
          id: crypto.randomUUID(),
          sourcePath: result.path,
          sourceFileName: result.fileName,
          fingerprint: result.fingerprint,
          order: guessed.order ?? fallbackOrder++,
          bandName: guessed.bandName,
          inFrame: 0,
          outFrameExclusive: result.media.frameCount,
          media: result.media,
          joinWithPrevious: false,
        });
      });

      if (imported.length > 0) {
        updateProject((latest) => ({
          ...latest,
          eventName: latest.eventName || parentFolderName(paths[0]),
          clips: sortClipsByOrder([...latest.clips, ...imported]),
        }));
        setSelectedClipId(imported[0].id);
      }
      if (failures.length > 0) setError(`読み込めなかった動画があります。\n${failures.join("\n")}`);
      if (imported.length > 0) showToast(`${imported.length}本追加しました${skipped ? `（${skipped}本は追加済み）` : ""}`);
      else if (skipped > 0) showToast("すべて追加済みの動画です");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(null);
    }
  }, [showToast, updateProject]);

  async function chooseVideoFiles() {
    const selection = await open({
      multiple: true,
      directory: false,
      filters: [{ name: "動画", extensions: VIDEO_EXTENSIONS.flatMap((extension) => [extension, extension.toUpperCase()]) }],
    });
    if (Array.isArray(selection)) await addVideoPaths(selection);
    else if (selection) await addVideoPaths([selection]);
  }

  async function listFolders(folders: string[]): Promise<string[]> {
    const found: string[] = [];
    for (const folder of folders) {
      try {
        found.push(...await invoke<string[]>("list_video_files", { folder }));
      } catch {
        // フォルダーでないものは無視する。
      }
    }
    return found;
  }

  async function chooseVideoFolder() {
    const folder = await open({ directory: true, multiple: false });
    if (!folder || Array.isArray(folder)) return;
    setBusy("フォルダーを確認しています");
    const paths = await listFolders([folder]);
    setBusy(null);
    if (paths.length === 0) {
      setError("このフォルダーには使える動画がありません。");
      return;
    }
    await addVideoPaths(paths);
  }

  async function relinkMissingSources() {
    const folder = await open({ directory: true, multiple: false });
    if (!folder || Array.isArray(folder)) return;
    setBusy("元動画を探しています");
    try {
      const candidates = await invoke<string[]>("list_video_files", { folder });
      const byName = new Map(candidates.map((path) => [basename(path).toLocaleLowerCase(), path]));
      const current = projectRef.current;
      const changed = current.clips.map((clip) => ({
        ...clip,
        sourcePath: clip.importError ? (byName.get(clip.sourceFileName.toLocaleLowerCase()) ?? clip.sourcePath) : clip.sourcePath,
      }));
      const refreshed = await refreshProjectMedia({ ...current, clips: changed });
      updateProject(() => refreshed);
      const stillMissing = refreshed.clips.filter((clip) => clip.importError).length;
      showToast(stillMissing ? `${stillMissing}本はまだ見つかりません` : "元動画が見つかりました");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(null);
    }
  }

  // ---- プロジェクトを開く・新規 ----

  function guardUnsaved(action: () => void) {
    if (!dirty || projectPath || projectRef.current.clips.length === 0) {
      action();
      return;
    }
    setConfirmation({
      title: "保存していない変更があります",
      body: "このまま続けると，今の編集内容は失われます。",
      confirmLabel: "保存せずに続ける",
      danger: true,
      onConfirm: action,
    });
  }

  function newProject() {
    replaceProject(EMPTY_PROJECT, { resetHistory: true });
    setProjectPath(null);
    setDirty(false);
    setRenderResult(null);
    setStep("import");
  }

  async function openProject() {
    const selection = await open({ multiple: false, directory: false, filters: PROJECT_FILTER });
    if (!selection || Array.isArray(selection)) return;
    setBusy("プロジェクトを開いています");
    setError(null);
    try {
      const loaded = await invoke<unknown>("read_project", { path: selection });
      if (!validateProject(loaded)) throw new Error("このアプリで作ったプロジェクトではないか，新しい版で保存されています。");
      let refreshed = await refreshProjectMedia(loaded);
      if (refreshed.thumbnail) {
        try {
          const prepared = await invoke<PreparedThumbnail>("prepare_thumbnail", { sourcePath: refreshed.thumbnail.sourcePath });
          refreshed = {
            ...refreshed,
            thumbnail: { ...refreshed.thumbnail, previewPath: prepared.previewPath, sourceWidth: prepared.sourceWidth, sourceHeight: prepared.sourceHeight, exifOrientation: prepared.exifOrientation },
          };
        } catch (reason) {
          setError(`サムネイルの写真を開けませんでした。\n${errorMessage(reason)}`);
        }
      }
      replaceProject(refreshed, { resetHistory: true });
      setProjectPath(selection);
      setSelectedClipId(refreshed.clips[0]?.id ?? null);
      setDirty(false);
      setSaveState("idle");
      setRenderResult(null);
      setStep("import");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(null);
    }
  }

  // ---- 動画一覧の編集 ----

  function updateClip(id: string, updater: (clip: ClipV1) => ClipV1, key?: string) {
    updateProject((current) => ({ ...current, clips: current.clips.map((clip) => (clip.id === id ? updater(clip) : clip)) }), key);
  }

  function updateBandName(id: string, bandName: string) {
    updateProject((current) => {
      const group = clipGroups(current.clips).find((candidate) => candidate.some((clip) => clip.id === id));
      if (!group) return current;
      const ids = new Set(group.map((clip) => clip.id));
      return {
        ...current,
        clips: current.clips.map((clip) => ids.has(clip.id) ? { ...clip, bandName, importError: clip.importError?.startsWith("ファイル名") ? undefined : clip.importError } : clip),
      };
    }, `band:${id}`);
  }

  function removeClip(id: string) {
    const removed = projectRef.current.clips.find((clip) => clip.id === id);
    updateProject((current) => {
      const clips = [...current.clips];
      const index = clips.findIndex((clip) => clip.id === id);
      if (index < 0) return current;
      const removedStartedBand = index === 0 || !clips[index].joinWithPrevious;
      clips.splice(index, 1);
      if (removedStartedBand && clips[index]?.joinWithPrevious) clips[index] = { ...clips[index], joinWithPrevious: false };
      return { ...current, clips: renumberClipOrders(clips) };
    });
    if (removed) showToast(`「${removed.bandName}」を外しました`, { label: "元に戻す", run: undo });
  }

  function moveClip(sourceId: string, targetId: string) {
    if (sourceId === targetId) return;
    updateProject((current) => {
      const clips = moveClipGroup(current.clips, sourceId, targetId);
      return clips === current.clips ? current : { ...current, clips };
    });
  }

  function moveClipByDirection(id: string, direction: -1 | 1) {
    updateProject((current) => {
      const groups = clipGroups(current.clips);
      const sourceIndex = groups.findIndex((group) => group.some((clip) => clip.id === id));
      const target = groups[sourceIndex + direction]?.[0];
      if (sourceIndex < 0 || !target) return current;
      return { ...current, clips: moveClipGroup(current.clips, id, target.id) };
    });
  }

  function setJoinWithPrevious(id: string, joined: boolean) {
    updateProject((current) => {
      const index = current.clips.findIndex((clip) => clip.id === id);
      if (index <= 0) return current;
      const clips = current.clips.map((clip) => ({ ...clip }));
      clips[index].joinWithPrevious = joined;
      if (joined) {
        let root = index - 1;
        while (root > 0 && clips[root].joinWithPrevious) root -= 1;
        const bandName = clips[root].bandName;
        for (let cursor = index; cursor < clips.length && (cursor === index || clips[cursor].joinWithPrevious); cursor += 1) {
          clips[cursor].bandName = bandName;
          if (clips[cursor].importError?.startsWith("ファイル名")) clips[cursor].importError = undefined;
        }
      }
      return { ...current, clips: renumberClipOrders(clips) };
    });
  }

  // ---- サムネイル ----

  const loadThumbnailPath = useCallback(async (sourcePath: string) => {
    setBusy("写真を読み込んでいます");
    setError(null);
    try {
      const prepared = await invoke<PreparedThumbnail>("prepare_thumbnail", { sourcePath });
      const thumbnail: ThumbnailV1 = { ...prepared, crop: centeredCropForAspect(prepared.sourceWidth, prepared.sourceHeight), zoom: 1 };
      updateProject((current) => ({ ...current, thumbnail: { ...thumbnail, outputFormat: current.thumbnail?.outputFormat ?? "jpg" } }));
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(null);
    }
  }, [updateProject]);

  async function chooseThumbnail() {
    const selection = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "画像", extensions: THUMBNAIL_EXTENSIONS.flatMap((extension) => [extension, extension.toUpperCase()]) }],
    });
    if (!selection || Array.isArray(selection)) return;
    await loadThumbnailPath(selection);
  }

  function updateThumbnailCrop(area: Area, zoom: number) {
    const crop = { x: area.x / 100, y: area.y / 100, width: area.width / 100, height: area.height / 100 };
    updateProject((current) => {
      if (!current.thumbnail) return current;
      const previous = current.thumbnail;
      const unchanged = Math.abs(previous.crop.x - crop.x) < 1e-6 && Math.abs(previous.crop.y - crop.y) < 1e-6
        && Math.abs(previous.crop.width - crop.width) < 1e-6 && Math.abs(previous.crop.height - crop.height) < 1e-6
        && Math.abs(previous.zoom - zoom) < 1e-6;
      return unchanged ? current : { ...current, thumbnail: { ...previous, crop, zoom } };
    }, "crop");
  }

  // ---- ドラッグ＆ドロップ ----

  const handleDroppedPaths = useCallback(async (paths: string[]) => {
    setFileDragActive(false);
    if (busy || renderJobId) return;
    if (step === "thumbnail") {
      const images = paths.filter(isThumbnailImagePath);
      if (images.length === 0) {
        setError("写真をドロップしてください（JPEG，PNG，HEIC，WebPなど）。");
        return;
      }
      await loadThumbnailPath(images[0]);
      return;
    }
    const videos = paths.filter(isVideoPath);
    const others = paths.filter((path) => !isVideoPath(path) && !isThumbnailImagePath(path));
    const fromFolders = others.length > 0 ? await listFolders(others) : [];
    const all = [...videos, ...fromFolders];
    if (all.length === 0) {
      setError("使える動画が見つかりませんでした（MP4，MOV，MKV，MTSなど）。");
      return;
    }
    await addVideoPaths(all);
  }, [addVideoPaths, busy, loadThumbnailPath, renderJobId, step]);

  useEffect(() => {
    setFileDragActive(false);
    const unlisten = getCurrentWindow().onDragDropEvent(({ payload }) => {
      if (payload.type === "enter") {
        const accepts = step === "thumbnail" ? payload.paths.some(isThumbnailImagePath) : payload.paths.length > 0;
        setFileDragActive(!busy && !renderJobId && accepts);
      } else if (payload.type === "leave") {
        setFileDragActive(false);
      } else if (payload.type === "drop") {
        void handleDroppedPaths(payload.paths);
      }
    });
    return () => {
      void unlisten.then((remove) => remove());
    };
  }, [busy, handleDroppedPaths, renderJobId, step]);

  // ---- 書き出し ----

  async function chooseOutputDirectory() {
    const folder = await open({ directory: true, multiple: false, defaultPath: outputDirectory || undefined });
    if (folder && !Array.isArray(folder)) updateProject((current) => ({ ...current, outputDirectory: folder }));
  }

  function buildRenderRequest(overwrite: boolean): RenderRequest {
    const current = projectRef.current;
    return {
      eventName: safeEventName(current.eventName),
      outputDirectory,
      resolution: current.outputResolution,
      frameRate: current.outputFrameRate ?? "59.94",
      clips: current.clips,
      thumbnail: current.thumbnail,
      overwrite,
    };
  }

  async function beginRender(overwrite: boolean) {
    try {
      const started = await invoke<RenderStarted>("start_render", { request: buildRenderRequest(overwrite) });
      setRenderJobId(started.jobId);
      setRenderProgress({ jobId: started.jobId, phase: "preparing", progress: 0, elapsedSeconds: 0, etaSeconds: null, encoder: null, message: "準備しています" });
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  async function startRender() {
    setError(null);
    setRenderResult(null);
    if (issues.length > 0) {
      setError(issues.map((issue) => issue.text).join("\n"));
      return;
    }
    try {
      const paths = await invoke<OutputPaths>("output_paths", { request: buildRenderRequest(false) });
      if (paths.existing.length > 0) {
        setConfirmation({
          title: "同じ名前のファイルがあります",
          body: `${paths.existing.map(basename).join("\n")}\n\n上書きしますか？`,
          confirmLabel: "上書きして書き出す",
          danger: true,
          onConfirm: () => void beginRender(true),
        });
        return;
      }
      await beginRender(false);
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  async function cancelRender() {
    if (renderJobId) await invoke("cancel_render", { jobId: renderJobId });
  }

  async function revealFile(path: string) {
    try {
      await invoke("reveal_in_folder", { path });
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  // ---- 終了 ----

  const closeWindow = useCallback(async (mode: "save" | "discard") => {
    if (closing) return;
    setClosing(true);
    try {
      if (mode === "save" && !(await saveProject(false))) {
        setClosing(false);
        return;
      }
      if (renderJobId) await invoke("cancel_render", { jobId: renderJobId });
      await getCurrentWindow().destroy();
    } catch (reason) {
      setClosing(false);
      setCloseRequested(false);
      setError(`終了できませんでした。\n${errorMessage(reason)}`);
    }
  }, [closing, renderJobId, saveProject]);

  useEffect(() => {
    const unlisten = getCurrentWindow().onCloseRequested((event) => {
      if (renderJobId) {
        event.preventDefault();
        setCloseRequested(true);
      } else if (dirty && projectPath) {
        // 保存先が決まっているので，確認せずに保存して閉じる。
        event.preventDefault();
        void closeWindow("save");
      } else if (dirty && projectRef.current.clips.length > 0) {
        event.preventDefault();
        setCloseRequested(true);
      }
    });
    return () => {
      void unlisten.then((remove) => remove());
    };
  }, [closeWindow, dirty, projectPath, renderJobId]);

  // ---- キーボードショートカット ----

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      const mod = isMac ? event.metaKey : event.ctrlKey;
      if (!mod || event.altKey) return;
      const key = event.key.toLowerCase();
      if (key === "z" && !event.shiftKey) { event.preventDefault(); undo(); }
      else if ((key === "z" && event.shiftKey) || (key === "y" && !isMac)) { event.preventDefault(); redo(); }
      else if (key === "s") { event.preventDefault(); if (!busy) void saveProject(event.shiftKey); }
      else if (key === "o") { event.preventDefault(); if (!busy && !renderJobId) guardUnsaved(() => void openProject()); }
      else if (key === "n") { event.preventDefault(); if (!busy && !renderJobId) guardUnsaved(newProject); }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  // ---- 画面 ----

  const importIssues = project.clips.length === 0 ? 0 : issues.filter((issue) => issue.step === "import").length;
  const saveLabel = saveState === "saving" ? "保存中…" : saveState === "error" ? "保存できませんでした" : dirty ? (projectPath ? "保存待ち" : "未保存") : projectPath ? "保存済み" : "";
  const locked = Boolean(busy || renderJobId);

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <img src={logoUrl} alt="" width={30} height={30} />
          <span className="project-name" title={projectPath ?? undefined}>
            {projectPath ? basename(projectPath).replace(/\.aovproj$/i, "") : "新しいプロジェクト"}
          </span>
          {saveLabel && <span className={`save-state ${saveState === "error" ? "is-error" : dirty ? "is-dirty" : ""}`}>{saveLabel}</span>}
        </div>

        <nav className="steps" aria-label="手順">
          {STEPS.map((item, index) => (
            <button
              key={item.id}
              className={step === item.id ? "active" : ""}
              aria-current={step === item.id ? "step" : undefined}
              onClick={() => setStep(item.id)}
              disabled={item.id !== "import" && project.clips.length === 0}
              title={item.id !== "import" && project.clips.length === 0 ? "先に動画を追加してください" : undefined}
            >
              <span className="step-index">{index + 1}</span>
              {item.label}
              {item.id === "import" && importIssues > 0 && <span className="badge" title="確認が必要な動画があります">{importIssues}</span>}
            </button>
          ))}
        </nav>

        <div className="toolbar">
          <button className="icon" onClick={undo} disabled={historySize.past === 0} title={`元に戻す（${MOD}Z）`} aria-label="元に戻す"><UndoIcon /></button>
          <button className="icon" onClick={redo} disabled={historySize.future === 0} title={`やり直す（${isMac ? "⌘⇧Z" : "Ctrl+Y"}）`} aria-label="やり直す"><RedoIcon /></button>
          <span className="toolbar-sep" />
          <button className="quiet" onClick={() => guardUnsaved(newProject)} disabled={locked} title={`${MOD}N`}>新規</button>
          <button className="quiet" onClick={() => guardUnsaved(() => void openProject())} disabled={locked} title={`${MOD}O`}>開く</button>
          <button className="quiet" onClick={() => void saveProject(false)} disabled={Boolean(busy)} title={`${MOD}S`}>保存</button>
          <button className="quiet" onClick={() => void saveProject(true)} disabled={Boolean(busy)} title={isMac ? "⌘⇧S" : "Ctrl+Shift+S"}>{isMac ? "別名で保存" : "名前を付けて保存"}</button>
        </div>
      </header>

      {toolStatus && (!toolStatus.ffmpegPath || !toolStatus.ffprobePath) && (
        <div className="alert alert-error">動画処理用のファイル（tools フォルダー）が見つかりません。アプリをフォルダーごと展開し直してください。</div>
      )}
      {error && (
        <div className="alert alert-error" role="alert">
          <pre>{error}</pre>
          <button className="quiet small" onClick={() => setError(null)}>閉じる</button>
        </div>
      )}

      <main className="workspace">
        {step === "import" && (
          <ImportStep
            project={project}
            busy={locked}
            onEventName={(eventName) => updateProject((current) => ({ ...current, eventName }), "event")}
            onChooseFiles={chooseVideoFiles}
            onChooseFolder={chooseVideoFolder}
            onRelink={relinkMissingSources}
            onBandName={updateBandName}
            onRemoveClip={removeClip}
            onSetJoin={setJoinWithPrevious}
            onMoveDirection={moveClipByDirection}
            onMove={moveClip}
            onEdit={(id) => { setSelectedClipId(id); setStep("trim"); }}
            onNext={() => setStep("trim")}
          />
        )}

        {step === "trim" && selectedClip && (
          <TrimStep
            clips={project.clips}
            selected={selectedClip}
            onSelect={setSelectedClipId}
            onUpdate={updateClip}
            onNext={() => setStep("thumbnail")}
            onError={setError}
          />
        )}

        {step === "thumbnail" && (
          <ThumbnailStep
            thumbnail={project.thumbnail}
            busy={locked}
            onChoose={chooseThumbnail}
            onRemove={() => updateProject((current) => ({ ...current, thumbnail: null }))}
            onFormat={(outputFormat) => updateProject((current) => ({ ...current, thumbnail: current.thumbnail ? { ...current.thumbnail, outputFormat } : null }))}
            onCropComplete={updateThumbnailCrop}
            onNext={() => setStep("export")}
          />
        )}

        {step === "export" && (
          <ExportStep
            project={project}
            outputDirectory={outputDirectory}
            issues={issues}
            renderJobId={renderJobId}
            progress={renderProgress}
            result={renderResult}
            onEventName={(eventName) => updateProject((current) => ({ ...current, eventName }), "event")}
            onResolution={(outputResolution) => updateProject((current) => ({ ...current, outputResolution }))}
            onFrameRate={(outputFrameRate) => updateProject((current) => ({ ...current, outputFrameRate }))}
            onChooseDirectory={chooseOutputDirectory}
            onGoToStep={setStep}
            onStart={startRender}
            onCancel={cancelRender}
            onReveal={revealFile}
            onToast={showToast}
            onError={setError}
          />
        )}
      </main>

      {fileDragActive && (
        <div className="drop-overlay" role="status">
          <strong>{step === "thumbnail" ? "写真をドロップ" : "動画またはフォルダーをドロップ"}</strong>
        </div>
      )}

      {busy && (
        <div className="busy" role="status" aria-live="polite">
          <div className="spinner" />
          <span>{busy}</span>
        </div>
      )}

      <div className="toasts" aria-live="polite">
        {toasts.map((toast) => (
          <div className="toast" key={toast.id}>
            <span>{toast.text}</span>
            {toast.action && (
              <button className="link" onClick={() => { toast.action!.run(); setToasts((current) => current.filter((item) => item.id !== toast.id)); }}>
                {toast.action.label}
              </button>
            )}
          </div>
        ))}
      </div>

      {confirmation && (
        <div className="modal-backdrop" role="presentation">
          <div className="modal" role="dialog" aria-modal="true" aria-labelledby="confirm-title">
            <h2 id="confirm-title">{confirmation.title}</h2>
            <p>{confirmation.body}</p>
            <div className="modal-actions">
              <button className="secondary" onClick={() => setConfirmation(null)} autoFocus>キャンセル</button>
              <button className={confirmation.danger ? "danger" : "primary"} onClick={() => { const run = confirmation.onConfirm; setConfirmation(null); run(); }}>
                {confirmation.confirmLabel}
              </button>
            </div>
          </div>
        </div>
      )}

      {closeRequested && (
        <div className="modal-backdrop" role="presentation">
          <div className="modal" role="dialog" aria-modal="true" aria-labelledby="close-title">
            <h2 id="close-title">{renderJobId ? "書き出しを中止して終了しますか？" : "保存してから終了しますか？"}</h2>
            <p>{renderJobId ? "次に書き出すときは最初からやり直しになります。" : "保存しないと，今の編集内容は失われます。"}</p>
            <div className="modal-actions">
              <button className="secondary" onClick={() => setCloseRequested(false)} disabled={closing}>キャンセル</button>
              <button className="danger" onClick={() => void closeWindow("discard")} disabled={closing}>{renderJobId ? "中止して終了" : "保存しない"}</button>
              {!renderJobId && <button className="primary" onClick={() => void closeWindow("save")} disabled={closing}>{closing ? "保存中…" : "保存して終了"}</button>}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
