import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent } from "react";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open, save } from "@tauri-apps/plugin-dialog";
import Cropper, { type Area, type Point } from "react-easy-crop";
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
  Resolution,
  ThumbnailV1,
  ToolStatus,
} from "./types";
import {
  basename,
  bandCount,
  chapterRows,
  chapterWarnings,
  centeredCropForAspect,
  clipDurationSeconds,
  clipGroups,
  duplicateOrders,
  estimateOutputBytes,
  formatBytes,
  formatChapterTime,
  formatClock,
  frameToSeconds,
  parentFolderName,
  parseClock,
  parseVideoFileName,
  projectDurationSeconds,
  moveClipGroup,
  renumberClipOrders,
  secondsToFrame,
  sortClipsByOrder,
  validateProject,
} from "./utils";

type Step = "import" | "trim" | "thumbnail" | "export";

const EMPTY_PROJECT: ProjectV1 = {
  schemaVersion: 1,
  appVersion: "0.2.1",
  eventName: "",
  clips: [],
  outputResolution: "1080p",
  transitionMs: 500,
  thumbnail: null,
};

const STEPS: Array<{ id: Step; index: number; label: string; description: string }> = [
  { id: "import", index: 1, label: "動画読込", description: "順番と名前" },
  { id: "trim", index: 2, label: "トリミング", description: "開始・終了位置" },
  { id: "thumbnail", index: 3, label: "サムネイル", description: "16:9切り抜き" },
  { id: "export", index: 4, label: "書き出し", description: "動画とチャプター" },
];

function errorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

function safeEventName(value: string): string {
  return value.trim().replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/, "") || "ライブ動画";
}

export default function App() {
  const [project, setProject] = useState<ProjectV1>(EMPTY_PROJECT);
  const [projectPath, setProjectPath] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [step, setStep] = useState<Step>("import");
  const [selectedClipId, setSelectedClipId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toolStatus, setToolStatus] = useState<ToolStatus | null>(null);
  const [draggedClipId, setDraggedClipId] = useState<string | null>(null);
  const [outputDirectory, setOutputDirectory] = useState("");
  const [renderJobId, setRenderJobId] = useState<string | null>(null);
  const [renderProgress, setRenderProgress] = useState<RenderProgress | null>(null);
  const [renderResult, setRenderResult] = useState<RenderFinished | null>(null);
  const [closeRequested, setCloseRequested] = useState(false);
  const [closing, setClosing] = useState(false);

  const selectedClip = project.clips.find((clip) => clip.id === selectedClipId) ?? project.clips[0] ?? null;
  const duplicateSet = useMemo(() => duplicateOrders(project.clips), [project.clips]);
  const durationSeconds = useMemo(() => projectDurationSeconds(project.clips), [project.clips]);

  const updateProject = useCallback((updater: (current: ProjectV1) => ProjectV1) => {
    setProject((current) => updater(current));
    setDirty(true);
  }, []);

  useEffect(() => {
    invoke<ToolStatus>("tool_status")
      .then(async (status) => {
        setToolStatus(status);
        if (status.fontPath) {
          try {
            const font = new FontFace("AOV Noto Sans JP", `url(${convertFileSrc(status.fontPath)})`, {
              weight: "900",
            });
            await font.load();
            document.fonts.add(font);
          } catch {
            // Windowsにインストール済みのNoto Sans JPへフォールバックする。
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
      if (payload.status === "completed") {
        setNotice("書き出しが完了しました。");
      } else if (payload.status === "failed") {
        setError(payload.error ?? "書き出しに失敗しました。");
      } else {
        setNotice("書き出しをキャンセルしました。");
      }
    });
    return () => {
      void unlistenProgress.then((unlisten) => unlisten());
      void unlistenFinished.then((unlisten) => unlisten());
    };
  }, []);

  useEffect(() => {
    const appWindow = getCurrentWindow();
    const unlisten = appWindow.onCloseRequested((event) => {
      if (dirty || renderJobId) {
        event.preventDefault();
        setCloseRequested(true);
      }
    });
    return () => {
      void unlisten.then((remove) => remove());
    };
  }, [dirty, renderJobId]);

  useEffect(() => {
    if (project.clips.length === 0) {
      setSelectedClipId(null);
    } else if (!project.clips.some((clip) => clip.id === selectedClipId)) {
      setSelectedClipId(project.clips[0].id);
    }
  }, [project.clips, selectedClipId]);

  const addVideoPaths = useCallback(
    async (paths: string[]) => {
      if (paths.length === 0) return;
      setBusy(true);
      setError(null);
      try {
        const results = await invoke<ProbeResult[]>("probe_media", { paths });
        const existing = new Set(project.clips.map((clip) => clip.sourcePath.toLocaleLowerCase()));
        const failures: string[] = [];
        const imported: ClipV1[] = [];
        let fallbackOrder = Math.max(0, ...project.clips.map((clip) => clip.order)) + 1;

        results.forEach((result) => {
          if (existing.has(result.path.toLocaleLowerCase())) return;
          if (!result.media) {
            failures.push(`${result.fileName}: ${result.error ?? "動画を解析できませんでした。"}`);
            return;
          }
          const parsed = parseVideoFileName(result.fileName);
          const order = parsed?.order ?? fallbackOrder++;
          imported.push({
            id: crypto.randomUUID(),
            sourcePath: result.path,
            sourceFileName: result.fileName,
            fingerprint: result.fingerprint,
            order,
            bandName: parsed?.bandName ?? result.fileName.replace(/\.[^.]+$/, ""),
            inFrame: 0,
            outFrameExclusive: result.media.frameCount,
            media: result.media,
            joinWithPrevious: false,
            importError: parsed ? undefined : "ファイル名を「出演順_バンド名.MP4」にしてください。",
          });
        });

        const clips = sortClipsByOrder([...project.clips, ...imported]);
        const inferredName = project.eventName || parentFolderName(paths[0]);
        setProject((current) => ({ ...current, eventName: inferredName, clips }));
        setDirty(imported.length > 0 || dirty);
        if (imported[0]) setSelectedClipId(imported[0].id);
        if (failures.length > 0) setError(failures.join("\n"));
        setNotice(`${imported.length}本の動画を読み込みました。`);
      } catch (reason) {
        setError(errorMessage(reason));
      } finally {
        setBusy(false);
      }
    },
    [dirty, project.clips, project.eventName],
  );

  async function chooseVideoFiles() {
    const selection = await open({
      multiple: true,
      directory: false,
      filters: [{ name: "MP4動画", extensions: ["mp4", "MP4"] }],
    });
    if (Array.isArray(selection)) await addVideoPaths(selection);
    else if (selection) await addVideoPaths([selection]);
  }

  async function chooseVideoFolder() {
    const folder = await open({ directory: true, multiple: false });
    if (!folder || Array.isArray(folder)) return;
    setBusy(true);
    try {
      const paths = await invoke<string[]>("list_mp4_files", { folder });
      await addVideoPaths(paths);
      if (paths.length === 0) setNotice("選択したフォルダーにMP4ファイルがありませんでした。");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(false);
    }
  }

  async function refreshProjectMedia(loaded: ProjectV1): Promise<ProjectV1> {
    if (loaded.clips.length === 0) return loaded;
    const results = await invoke<ProbeResult[]>("probe_media", { paths: loaded.clips.map((clip) => clip.sourcePath) });
    const byPath = new Map(results.map((result) => [result.path.toLocaleLowerCase(), result]));
    return {
      ...loaded,
      clips: loaded.clips.map((clip) => {
        const current = byPath.get(clip.sourcePath.toLocaleLowerCase());
        if (!current?.media) return { ...clip, importError: current?.error ?? "元動画が見つかりません。" };
        const inFrame = Math.min(clip.inFrame, Math.max(0, current.media.frameCount - 1));
        const outFrameExclusive = Math.max(inFrame + 1, Math.min(clip.outFrameExclusive, current.media.frameCount));
        return {
          ...clip,
          media: current.media,
          fingerprint: current.fingerprint,
          inFrame,
          outFrameExclusive,
          importError: undefined,
        };
      }),
    };
  }

  async function openProject() {
    const selection = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "ARTOFFICE動画プロジェクト", extensions: ["aovproj"] }],
    });
    if (!selection || Array.isArray(selection)) return;
    setBusy(true);
    setError(null);
    try {
      const loaded = await invoke<unknown>("read_project", { path: selection });
      if (!validateProject(loaded)) throw new Error("対応していないプロジェクト形式です。");
      let refreshed = await refreshProjectMedia(loaded);
      if (refreshed.thumbnail) {
        try {
          const prepared = await invoke<PreparedThumbnail>("prepare_thumbnail", {
            sourcePath: refreshed.thumbnail.sourcePath,
          });
          refreshed = {
            ...refreshed,
            thumbnail: {
              ...refreshed.thumbnail,
              previewPath: prepared.previewPath,
              sourceWidth: prepared.sourceWidth,
              sourceHeight: prepared.sourceHeight,
              exifOrientation: prepared.exifOrientation,
            },
          };
        } catch (reason) {
          setNotice(`サムネイル画像を再読込できませんでした: ${errorMessage(reason)}`);
        }
      }
      setProject(refreshed);
      setProjectPath(selection);
      setSelectedClipId(refreshed.clips[0]?.id ?? null);
      setDirty(false);
      setStep("import");
      setNotice("プロジェクトを開きました。");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(false);
    }
  }

  async function saveProject(saveAs = false): Promise<boolean> {
    try {
      let destination = saveAs ? null : projectPath;
      if (!destination) {
        destination = await save({
          defaultPath: `${safeEventName(project.eventName)}.aovproj`,
          filters: [{ name: "ARTOFFICE動画プロジェクト", extensions: ["aovproj"] }],
        });
      }
      if (!destination) return false;
      if (!destination.toLocaleLowerCase().endsWith(".aovproj")) destination += ".aovproj";
      await invoke("write_project", { path: destination, project });
      setProjectPath(destination);
      setDirty(false);
      setNotice("プロジェクトを保存しました。");
      return true;
    } catch (reason) {
      setError(errorMessage(reason));
      return false;
    }
  }

  async function relinkMissingSources() {
    const folder = await open({ directory: true, multiple: false });
    if (!folder || Array.isArray(folder)) return;
    setBusy(true);
    try {
      const candidates = await invoke<string[]>("list_mp4_files", { folder });
      const byName = new Map(candidates.map((path) => [basename(path).toLocaleLowerCase(), path]));
      const changed = project.clips.map((clip) => ({
        ...clip,
        sourcePath: clip.importError ? (byName.get(clip.sourceFileName.toLocaleLowerCase()) ?? clip.sourcePath) : clip.sourcePath,
      }));
      const refreshed = await refreshProjectMedia({ ...project, clips: changed });
      setProject(refreshed);
      setDirty(true);
      setNotice("元動画の再リンクを確認しました。");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(false);
    }
  }

  function updateClip(id: string, updater: (clip: ClipV1) => ClipV1) {
    updateProject((current) => ({
      ...current,
      clips: current.clips.map((clip) => (clip.id === id ? updater(clip) : clip)),
    }));
  }

  function updateBandName(id: string, bandName: string) {
    updateProject((current) => {
      const groups = clipGroups(current.clips);
      const group = groups.find((candidate) => candidate.some((clip) => clip.id === id));
      if (!group) return current;
      const ids = new Set(group.map((clip) => clip.id));
      return {
        ...current,
        clips: current.clips.map((clip) => ids.has(clip.id) ? {
          ...clip,
          bandName,
          importError: clip.importError?.startsWith("ファイル名") ? undefined : clip.importError,
        } : clip),
      };
    });
  }

  function removeClip(id: string) {
    updateProject((current) => {
      const clips = [...current.clips];
      const index = clips.findIndex((clip) => clip.id === id);
      if (index < 0) return current;
      const removedStartedBand = index === 0 || !clips[index].joinWithPrevious;
      clips.splice(index, 1);
      if (removedStartedBand && clips[index]?.joinWithPrevious) {
        clips[index] = { ...clips[index], joinWithPrevious: false };
      }
      return { ...current, clips: renumberClipOrders(clips) };
    });
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
        let previousRoot = index - 1;
        while (previousRoot > 0 && clips[previousRoot].joinWithPrevious) previousRoot -= 1;
        const bandName = clips[previousRoot].bandName;
        clips[index].bandName = bandName;
        if (clips[index].importError?.startsWith("ファイル名")) clips[index].importError = undefined;
        for (let cursor = index + 1; cursor < clips.length && clips[cursor].joinWithPrevious; cursor += 1) {
          clips[cursor].bandName = bandName;
          if (clips[cursor].importError?.startsWith("ファイル名")) clips[cursor].importError = undefined;
        }
      }
      return { ...current, clips: renumberClipOrders(clips) };
    });
    setNotice(joined
      ? "前の動画と同じバンドの分割パートとして連結します。"
      : "この動画を別のバンドとして扱います。");
  }

  async function chooseThumbnail() {
    const selection = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "集合写真", extensions: ["jpg", "jpeg", "png", "heic", "heif", "JPG", "PNG", "HEIC"] }],
    });
    if (!selection || Array.isArray(selection)) return;
    setBusy(true);
    setError(null);
    try {
      const prepared = await invoke<PreparedThumbnail>("prepare_thumbnail", { sourcePath: selection });
      const thumbnail: ThumbnailV1 = {
        ...prepared,
        crop: centeredCropForAspect(prepared.sourceWidth, prepared.sourceHeight),
        zoom: 1,
      };
      updateProject((current) => ({ ...current, thumbnail }));
      setNotice("集合写真を読み込みました。枠内をドラッグして調整してください。");
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setBusy(false);
    }
  }

  function updateThumbnailCrop(area: Area, zoom: number) {
    if (!project.thumbnail) return;
    const crop = {
      x: area.x / 100,
      y: area.y / 100,
      width: area.width / 100,
      height: area.height / 100,
    };
    updateProject((current) => {
      if (!current.thumbnail) return current;
      const previous = current.thumbnail;
      const unchanged =
        Math.abs(previous.crop.x - crop.x) < 1e-6 &&
        Math.abs(previous.crop.y - crop.y) < 1e-6 &&
        Math.abs(previous.crop.width - crop.width) < 1e-6 &&
        Math.abs(previous.crop.height - crop.height) < 1e-6 &&
        Math.abs(previous.zoom - zoom) < 1e-6;
      return unchanged ? current : { ...current, thumbnail: { ...previous, crop, zoom } };
    });
  }

  async function chooseOutputDirectory() {
    const folder = await open({ directory: true, multiple: false });
    if (folder && !Array.isArray(folder)) setOutputDirectory(folder);
  }

  function buildRenderRequest(overwrite: boolean): RenderRequest {
    return {
      eventName: safeEventName(project.eventName),
      outputDirectory,
      resolution: project.outputResolution,
      clips: project.clips,
      thumbnail: project.thumbnail,
      overwrite,
    };
  }

  async function startRender() {
    setError(null);
    setRenderResult(null);
    if (!project.eventName.trim()) {
      setError("イベント名を入力してください。");
      return;
    }
    if (!outputDirectory) {
      setError("保存先フォルダーを選択してください。");
      return;
    }
    if (project.clips.length === 0) {
      setError("動画を1本以上読み込んでください。");
      return;
    }
    if (project.clips.some((clip) => clip.importError || !clip.media.hasAudio)) {
      setError("読込エラーまたは音声のない動画があります。動画読込画面で確認してください。");
      return;
    }
    try {
      const preliminary = buildRenderRequest(false);
      const paths = await invoke<OutputPaths>("output_paths", { request: preliminary });
      let overwrite = false;
      if (paths.existing.length > 0) {
        overwrite = window.confirm(
          `次のファイルが既にあります。上書きしますか？\n\n${paths.existing.join("\n")}`,
        );
        if (!overwrite) return;
      }
      const started = await invoke<RenderStarted>("start_render", { request: buildRenderRequest(overwrite) });
      setRenderJobId(started.jobId);
      setRenderProgress({
        jobId: started.jobId,
        phase: "preparing",
        progress: 0,
        elapsedSeconds: 0,
        etaSeconds: null,
        encoder: null,
        message: "書き出しを準備しています。",
      });
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  async function cancelRender() {
    if (!renderJobId) return;
    await invoke("cancel_render", { jobId: renderJobId });
  }

  async function closeDiscardingChanges() {
    if (closing) return;
    setClosing(true);
    try {
      if (renderJobId) await cancelRender();
      await getCurrentWindow().destroy();
    } catch (reason) {
      setClosing(false);
      setCloseRequested(false);
      setError(`アプリを終了できませんでした。\n${errorMessage(reason)}`);
    }
  }

  async function saveAndClose() {
    if (closing) return;
    setClosing(true);
    try {
      const saved = await saveProject(false);
      if (!saved) {
        setClosing(false);
        return;
      }
      await getCurrentWindow().destroy();
    } catch (reason) {
      setClosing(false);
      setCloseRequested(false);
      setError(`アプリを終了できませんでした。\n${errorMessage(reason)}`);
    }
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true"><span>▶</span></div>
          <div>
            <strong>ARTOFFICE</strong>
            <small>広報動画作成ソフト</small>
          </div>
        </div>
        <div className="project-title">
          <span>{projectPath ? basename(projectPath) : "未保存のプロジェクト"}</span>
          {dirty && <span className="dirty-dot" title="未保存の変更があります">●</span>}
        </div>
        <div className="toolbar-actions">
          <button className="ghost" onClick={openProject} disabled={busy || Boolean(renderJobId)}>開く</button>
          <button className="ghost" onClick={() => void saveProject(false)} disabled={busy}>保存</button>
          <button className="ghost" onClick={() => void saveProject(true)} disabled={busy}>名前を付けて保存</button>
        </div>
      </header>

      <nav className="step-nav" aria-label="編集手順">
        {STEPS.map((item) => (
          <button
            key={item.id}
            className={step === item.id ? "active" : ""}
            onClick={() => setStep(item.id)}
            disabled={item.id !== "import" && project.clips.length === 0}
          >
            <span className="step-number">{item.index}</span>
            <span><strong>{item.label}</strong><small>{item.description}</small></span>
          </button>
        ))}
      </nav>

      <main className="workspace">
        {toolStatus && (!toolStatus.ffmpegPath || !toolStatus.ffprobePath) && (
          <div className="banner error-banner">FFmpegまたはFFprobeが見つかりません。vendor-toolsを準備してください。</div>
        )}
        {notice && <div className="banner notice-banner"><span>{notice}</span><button onClick={() => setNotice(null)}>閉じる</button></div>}
        {error && <div className="banner error-banner"><pre>{error}</pre><button onClick={() => setError(null)}>閉じる</button></div>}

        {step === "import" && (
          <ImportStep
            project={project}
            busy={busy}
            duplicateSet={duplicateSet}
            draggedClipId={draggedClipId}
            onEventName={(eventName) => updateProject((current) => ({ ...current, eventName }))}
            onChooseFiles={chooseVideoFiles}
            onChooseFolder={chooseVideoFolder}
            onRelink={relinkMissingSources}
            onBandName={updateBandName}
            onRemoveClip={removeClip}
            onSetJoin={setJoinWithPrevious}
            onMoveDirection={moveClipByDirection}
            onDragStart={setDraggedClipId}
            onDrop={(sourceId, targetId) => {
              moveClip(sourceId, targetId);
              setDraggedClipId(null);
            }}
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
            onError={(message) => setError(message)}
          />
        )}

        {step === "thumbnail" && (
          <ThumbnailStep
            thumbnail={project.thumbnail}
            busy={busy}
            onChoose={chooseThumbnail}
            onRemove={() => updateProject((current) => ({ ...current, thumbnail: null }))}
            onCropComplete={updateThumbnailCrop}
            onNext={() => setStep("export")}
          />
        )}

        {step === "export" && (
          <ExportStep
            project={project}
            durationSeconds={durationSeconds}
            outputDirectory={outputDirectory}
            renderJobId={renderJobId}
            progress={renderProgress}
            result={renderResult}
            onResolution={(outputResolution) => updateProject((current) => ({ ...current, outputResolution }))}
            onChooseDirectory={chooseOutputDirectory}
            onStart={startRender}
            onCancel={cancelRender}
          />
        )}
      </main>

      {busy && <div className="busy-overlay"><div className="spinner" /><span>処理しています…</span></div>}

      {closeRequested && (
        <div className="modal-backdrop" role="presentation">
          <div className="modal" role="dialog" aria-modal="true" aria-labelledby="close-title">
            <h2 id="close-title">アプリを終了しますか？</h2>
            <p>{renderJobId ? "書き出しをキャンセルして終了します。" : "保存していない変更があります。"}</p>
            <div className="modal-actions">
              {!renderJobId && <button className="primary" onClick={saveAndClose} disabled={closing}>{closing ? "終了処理中…" : "保存して終了"}</button>}
              <button className="danger" onClick={closeDiscardingChanges} disabled={closing}>{closing ? "終了処理中…" : renderJobId ? "中止して終了" : "破棄して終了"}</button>
              <button className="ghost" onClick={() => setCloseRequested(false)} disabled={closing}>キャンセル</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

interface ImportStepProps {
  project: ProjectV1;
  busy: boolean;
  duplicateSet: Set<number>;
  draggedClipId: string | null;
  onEventName: (value: string) => void;
  onChooseFiles: () => void;
  onChooseFolder: () => void;
  onRelink: () => void;
  onBandName: (id: string, value: string) => void;
  onRemoveClip: (id: string) => void;
  onSetJoin: (id: string, joined: boolean) => void;
  onMoveDirection: (id: string, direction: -1 | 1) => void;
  onDragStart: (id: string | null) => void;
  onDrop: (sourceId: string, targetId: string) => void;
  onNext: () => void;
}

function ImportStep(props: ImportStepProps) {
  const hasMissing = props.project.clips.some((clip) => Boolean(clip.importError));
  const groups = clipGroups(props.project.clips);
  const positions = new Map<string, { groupIndex: number; partIndex: number; partCount: number }>();
  groups.forEach((group, groupIndex) => group.forEach((clip, partIndex) => {
    positions.set(clip.id, { groupIndex, partIndex, partCount: group.length });
  }));

  function beginDrag(event: DragEvent<HTMLElement>, id: string) {
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", id);
    props.onDragStart(id);
  }

  function acceptDrop(event: DragEvent<HTMLElement>, targetId: string) {
    event.preventDefault();
    const sourceId = event.dataTransfer.getData("text/plain") || props.draggedClipId;
    if (sourceId) props.onDrop(sourceId, targetId);
  }

  return (
    <section className="step-panel">
      <div className="section-heading">
        <div><span className="eyebrow">STEP 1</span><h1>動画を読み込む</h1></div>
        <div className="heading-actions">
          <button className="secondary" onClick={props.onChooseFiles} disabled={props.busy}>MP4を選択</button>
          <button className="primary" onClick={props.onChooseFolder} disabled={props.busy}>フォルダーを選択</button>
        </div>
      </div>

      <label className="field event-name-field">
        <span>イベント名</span>
        <input value={props.project.eventName} onChange={(event) => props.onEventName(event.target.value)} />
      </label>

      {props.project.clips.length === 0 ? (
        <div className="empty-state">
          <div className="empty-icon">＋</div>
          <h2>ライブ動画を追加してください</h2>
        </div>
      ) : (
        <div className="clip-table-wrap">
          <div className="clip-table-header">
            <span>{bandCount(props.project.clips)}バンド・動画{props.project.clips.length}本・ハンドルをドラッグして並べ替え</span>
            {hasMissing && <button className="secondary small" onClick={props.onRelink}>元動画を再リンク</button>}
          </div>
          <div className="clip-table">
            {props.project.clips.map((clip, index) => {
              const position = positions.get(clip.id)!;
              const joined = position.partIndex > 0;
              return (
              <div
                key={clip.id}
                className={`clip-row ${props.draggedClipId === clip.id ? "dragging" : ""} ${joined ? "continuation" : ""}`}
                onDragOver={(event) => {
                  event.preventDefault();
                  event.dataTransfer.dropEffect = "move";
                }}
                onDrop={(event) => acceptDrop(event, clip.id)}
              >
                <span
                  className="drag-handle"
                  title="ドラッグして並べ替え"
                  draggable
                  aria-label={`${clip.bandName}を並べ替え`}
                  onDragStart={(event) => beginDrag(event, clip.id)}
                  onDragEnd={() => props.onDragStart(null)}
                >⠿</span>
                <span className={`order-badge ${props.duplicateSet.has(clip.order) ? "warning" : ""}`} title={joined ? `パート${position.partIndex + 1}` : `出演順${clip.order}`}>
                  {joined ? "↳" : clip.order}
                </span>
                <div className="clip-name-cell">
                  <input
                    value={clip.bandName}
                    disabled={joined}
                    onChange={(event) => props.onBandName(clip.id, event.target.value)}
                    aria-label={`${index + 1}番目のバンド名`}
                  />
                  <small title={clip.sourcePath}>{joined ? `連結パート${position.partIndex + 1}・` : ""}{clip.sourceFileName}</small>
                </div>
                <div className="media-summary">
                  <span>{clip.media.width}×{clip.media.height}</span>
                  <span>{(clip.media.fps.numerator / clip.media.fps.denominator).toFixed(2)}fps</span>
                  <span>{formatClock(clip.media.durationSeconds).replace(/\.\d{3}$/, "")}</span>
                </div>
                <div className="status-cell">
                  {clip.importError ? <span className="status error">要確認</span> : clip.media.needsConversion ? <span className="status convert">変換します</span> : <span className="status ready">準備完了</span>}
                  {(clip.importError || clip.media.conversionReasons.length > 0) && (
                    <small>{clip.importError ?? clip.media.conversionReasons.join("，")}</small>
                  )}
                </div>
                <div className="join-cell">
                  {index === 0 ? (
                    <span>先頭の動画</span>
                  ) : (
                    <button
                      className={joined ? "join-button active" : "join-button"}
                      onClick={() => props.onSetJoin(clip.id, !joined)}
                      title={joined ? "この動画を別のバンドに戻す" : "前の動画と同じバンドとして直結する"}
                    >{joined ? "✓ 前と連結" : "前と連結"}</button>
                  )}
                </div>
                <div className="move-buttons">
                  <button onClick={() => props.onMoveDirection(clip.id, -1)} disabled={position.groupIndex === 0} aria-label={`${clip.bandName}を上へ移動`}>↑</button>
                  <button onClick={() => props.onMoveDirection(clip.id, 1)} disabled={position.groupIndex === groups.length - 1} aria-label={`${clip.bandName}を下へ移動`}>↓</button>
                </div>
                <button className="icon-button" onClick={() => props.onRemoveClip(clip.id)} aria-label={`${clip.bandName}を削除`}>×</button>
              </div>
              );
            })}
          </div>
        </div>
      )}

      <div className="step-footer">
        <button className="primary" onClick={props.onNext} disabled={props.project.clips.length === 0}>トリミングへ進む <span>→</span></button>
      </div>
    </section>
  );
}

interface TrimStepProps {
  clips: ClipV1[];
  selected: ClipV1;
  onSelect: (id: string) => void;
  onUpdate: (id: string, updater: (clip: ClipV1) => ClipV1) => void;
  onNext: () => void;
  onError: (message: string) => void;
}

function TrimStep({ clips, selected, onSelect, onUpdate, onNext, onError }: TrimStepProps) {
  const playerRef = useRef<HTMLVideoElement>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [transitionPreview, setTransitionPreview] = useState<string | null>(null);
  const [previewBusy, setPreviewBusy] = useState(false);
  const fps = selected.media.fps;
  const inSeconds = frameToSeconds(selected.inFrame, fps);
  const outSeconds = frameToSeconds(selected.outFrameExclusive, fps);
  const titleTime = currentTime - inSeconds;
  const titleOpacity = selected.joinWithPrevious || titleTime < 0 || titleTime >= 5 ? 0 : titleTime < 0.5 ? titleTime / 0.5 : titleTime < 4.5 ? 1 : (5 - titleTime) / 0.5;
  const nextIndex = clips.findIndex((clip) => clip.id === selected.id) + 1;
  const nextClip = nextIndex > 0 && nextIndex < clips.length ? clips[nextIndex] : null;
  const groups = clipGroups(clips);
  const positions = new Map<string, { bandIndex: number; partIndex: number; partCount: number }>();
  groups.forEach((group, bandIndex) => group.forEach((clip, partIndex) => {
    positions.set(clip.id, { bandIndex, partIndex, partCount: group.length });
  }));
  const selectedPosition = positions.get(selected.id)!;

  useEffect(() => {
    setCurrentTime(inSeconds);
    setTransitionPreview(null);
    if (playerRef.current) playerRef.current.currentTime = inSeconds;
  }, [selected.id, inSeconds]);

  function seek(seconds: number) {
    const clamped = Math.min(outSeconds, Math.max(inSeconds, seconds));
    if (playerRef.current) playerRef.current.currentTime = clamped;
    setCurrentTime(clamped);
  }

  function setInFromCurrent() {
    const frame = Math.min(selected.outFrameExclusive - 1, secondsToFrame(currentTime, fps));
    onUpdate(selected.id, (clip) => ({ ...clip, inFrame: frame }));
  }

  function setOutFromCurrent() {
    const frame = Math.max(selected.inFrame + 1, secondsToFrame(currentTime, fps));
    onUpdate(selected.id, (clip) => ({ ...clip, outFrameExclusive: Math.min(frame, clip.media.frameCount) }));
  }

  async function renderTransitionPreview() {
    if (!nextClip) return;
    setPreviewBusy(true);
    try {
      const path = await invoke<string>("render_transition_preview", {
        request: { current: selected, next: nextClip },
      });
      setTransitionPreview(convertFileSrc(path));
    } catch (reason) {
      onError(errorMessage(reason));
    } finally {
      setPreviewBusy(false);
    }
  }

  return (
    <section className="editor-layout">
      <aside className="clip-sidebar">
        <div className="sidebar-title"><span>{bandCount(clips)}バンド・動画{clips.length}本</span><strong>{clips.length}</strong></div>
        {clips.map((clip) => {
          const position = positions.get(clip.id)!;
          return (
          <button key={clip.id} className={clip.id === selected.id ? "selected" : ""} onClick={() => onSelect(clip.id)}>
            <span>{position.partCount > 1 ? `${position.bandIndex + 1}.${position.partIndex + 1}` : position.bandIndex + 1}</span>
            <div><strong>{clip.bandName}{position.partCount > 1 ? `・パート${position.partIndex + 1}` : ""}</strong><small>{formatClock(clipDurationSeconds(clip)).replace(/\.\d{3}$/, "")}</small></div>
          </button>
          );
        })}
      </aside>

      <div className="trim-workspace">
        <div className="section-heading compact">
          <div><span className="eyebrow">STEP 2</span><h1>{selected.bandName}{selectedPosition.partCount > 1 ? `・パート${selectedPosition.partIndex + 1}` : ""}</h1></div>
          <span className="clip-counter">{clips.findIndex((clip) => clip.id === selected.id) + 1} / {clips.length}</span>
        </div>

        <div className="video-stage">
          <video
            key={selected.sourcePath}
            ref={playerRef}
            src={convertFileSrc(selected.sourcePath)}
            controls
            preload="metadata"
            onLoadedMetadata={() => seek(inSeconds)}
            onTimeUpdate={(event) => {
              const video = event.currentTarget;
              setCurrentTime(video.currentTime);
              if (video.currentTime >= outSeconds) {
                video.pause();
                video.currentTime = outSeconds;
              }
            }}
          />
          <div className="band-title-preview" style={{ opacity: Math.max(0, Math.min(1, titleOpacity)) }}>{selected.bandName}</div>
        </div>

        <div className="timeline-card">
          <div className="timeline-labels"><span>開始 {formatClock(inSeconds)}</span><strong>{formatClock(currentTime)}</strong><span>終了 {formatClock(outSeconds)}</span></div>
          <div className="dual-range">
            <div className="range-fill" style={{ left: `${(selected.inFrame / selected.media.frameCount) * 100}%`, right: `${100 - (selected.outFrameExclusive / selected.media.frameCount) * 100}%` }} />
            <input
              type="range"
              min={0}
              max={Math.max(1, selected.media.frameCount - 1)}
              value={selected.inFrame}
              onChange={(event) => onUpdate(selected.id, (clip) => ({ ...clip, inFrame: Math.min(Number(event.target.value), clip.outFrameExclusive - 1) }))}
              aria-label="開始フレーム"
            />
            <input
              type="range"
              min={1}
              max={selected.media.frameCount}
              value={selected.outFrameExclusive}
              onChange={(event) => onUpdate(selected.id, (clip) => ({ ...clip, outFrameExclusive: Math.max(Number(event.target.value), clip.inFrame + 1) }))}
              aria-label="終了フレーム"
            />
          </div>

          <div className="trim-controls">
            <div className="mark-control">
              <label>開始点</label>
              <input
                key={`in-${selected.id}-${selected.inFrame}`}
                defaultValue={formatClock(inSeconds)}
                onBlur={(event) => {
                  const seconds = parseClock(event.target.value);
                  if (seconds === null) return onError("開始点はH:MM:SS.mmm形式で入力してください。");
                  onUpdate(selected.id, (clip) => ({ ...clip, inFrame: Math.min(secondsToFrame(seconds, fps), clip.outFrameExclusive - 1) }));
                }}
              />
              <button className="secondary" onClick={setInFromCurrent}>現在位置を設定</button>
            </div>
            <div className="frame-controls">
              <button onClick={() => seek(currentTime - 1 / (fps.numerator / fps.denominator))}>−1フレーム</button>
              <button onClick={() => seek(inSeconds)}>開始へ</button>
              <button onClick={() => seek(Math.max(inSeconds, outSeconds - 3))}>終了前を確認</button>
              <button onClick={() => seek(currentTime + 1 / (fps.numerator / fps.denominator))}>＋1フレーム</button>
            </div>
            <div className="mark-control end">
              <label>終了点</label>
              <input
                key={`out-${selected.id}-${selected.outFrameExclusive}`}
                defaultValue={formatClock(outSeconds)}
                onBlur={(event) => {
                  const seconds = parseClock(event.target.value);
                  if (seconds === null) return onError("終了点はH:MM:SS.mmm形式で入力してください。");
                  onUpdate(selected.id, (clip) => ({ ...clip, outFrameExclusive: Math.max(secondsToFrame(seconds, fps), clip.inFrame + 1) }));
                }}
              />
              <button className="secondary" onClick={setOutFromCurrent}>現在位置を設定</button>
            </div>
          </div>
        </div>

        <div className="transition-preview-card">
          <div><strong>{nextClip?.joinWithPrevious ? "分割動画の連結プレビュー" : "つなぎ目プレビュー"}</strong><small>{nextClip ? nextClip.joinWithPrevious ? `${selected.sourceFileName}の直後に${nextClip.sourceFileName}を連結` : `${selected.bandName} → ${nextClip.bandName}` : "最後の動画です"}</small></div>
          {transitionPreview && <video src={transitionPreview} controls autoPlay />}
          <button className="secondary" disabled={!nextClip || previewBusy} onClick={renderTransitionPreview}>{previewBusy ? "作成中…" : nextClip?.joinWithPrevious ? "連結部分を確認" : "0.5秒クロスフェードを確認"}</button>
        </div>

        <div className="step-footer"><button className="primary" onClick={onNext}>サムネイルへ進む <span>→</span></button></div>
      </div>
    </section>
  );
}

interface ThumbnailStepProps {
  thumbnail: ThumbnailV1 | null;
  busy: boolean;
  onChoose: () => void;
  onRemove: () => void;
  onCropComplete: (area: Area, zoom: number) => void;
  onNext: () => void;
}

function ThumbnailStep({ thumbnail, busy, onChoose, onRemove, onCropComplete, onNext }: ThumbnailStepProps) {
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(thumbnail?.zoom ?? 1);
  const initialCroppedArea = useMemo<Area | undefined>(() => thumbnail ? {
    x: thumbnail.crop.x * 100,
    y: thumbnail.crop.y * 100,
    width: thumbnail.crop.width * 100,
    height: thumbnail.crop.height * 100,
  } : undefined, [thumbnail?.sourcePath]);
  const croppedAreaRef = useRef<Area | null>(initialCroppedArea ?? null);

  useEffect(() => {
    setCrop({ x: 0, y: 0 });
    setZoom(thumbnail?.zoom ?? 1);
    croppedAreaRef.current = initialCroppedArea ?? null;
  }, [thumbnail?.sourcePath, initialCroppedArea]);

  const handleCropChange = useCallback((next: Point) => {
    setCrop((current) =>
      Math.abs(current.x - next.x) < 1e-6 && Math.abs(current.y - next.y) < 1e-6 ? current : next,
    );
  }, []);

  const handleZoomChange = useCallback((next: number) => {
    setZoom((current) => Math.abs(current - next) < 1e-6 ? current : next);
  }, []);

  const rememberCrop = useCallback((area: Area) => {
    croppedAreaRef.current = area;
  }, []);

  const commitCrop = useCallback(() => {
    if (croppedAreaRef.current) onCropComplete(croppedAreaRef.current, zoom);
  }, [onCropComplete, zoom]);

  return (
    <section className="step-panel">
      <div className="section-heading">
        <div><span className="eyebrow">STEP 3</span><h1>サムネイルを切り抜く</h1></div>
        <div className="heading-actions"><button className="primary" onClick={onChoose} disabled={busy}>集合写真を選択</button></div>
      </div>

      {!thumbnail ? (
        <div className="empty-state thumbnail-empty">
          <div className="empty-icon photo">▧</div><p>JPG，PNG，HEIC，HEIFに対応します。選択しない場合，サムネイルは出力しません。</p>
          <button className="secondary" onClick={onChoose} disabled={busy}>{busy ? "画像を処理中…" : "写真を選択"}</button>
        </div>
      ) : (
        <div className="thumbnail-editor">
          <div className="crop-stage">
            <Cropper
              image={convertFileSrc(thumbnail.previewPath)}
              crop={crop}
              zoom={zoom}
              aspect={16 / 9}
              showGrid
              initialCroppedAreaPercentages={initialCroppedArea}
              onCropChange={handleCropChange}
              onZoomChange={handleZoomChange}
              onCropComplete={rememberCrop}
              onCropAreaChange={rememberCrop}
              onInteractionEnd={commitCrop}
            />
          </div>
          <aside className="crop-settings">
            <h2>切り抜き設定</h2>
            <div className="source-card"><span>元画像</span><strong title={thumbnail.sourcePath}>{basename(thumbnail.sourcePath)}</strong><small>{thumbnail.sourceWidth}×{thumbnail.sourceHeight}</small></div>
            <label className="field"><span>拡大率</span><input type="range" min={1} max={4} step={0.01} value={zoom} onChange={(event) => handleZoomChange(Number(event.target.value))} onPointerUp={commitCrop} onKeyUp={commitCrop} onBlur={commitCrop} /><small>{zoom.toFixed(2)}倍</small></label>
            <p className="hint">写真をドラッグして全員が枠内に入るよう調整します。出力時に高品質補間を行います。</p>
            <button className="danger text" onClick={onRemove}>集合写真を削除</button>
          </aside>
        </div>
      )}

      <div className="step-footer"><button className="primary" onClick={onNext}>書き出しへ進む <span>→</span></button></div>
    </section>
  );
}

interface ExportStepProps {
  project: ProjectV1;
  durationSeconds: number;
  outputDirectory: string;
  renderJobId: string | null;
  progress: RenderProgress | null;
  result: RenderFinished | null;
  onResolution: (value: Resolution) => void;
  onChooseDirectory: () => void;
  onStart: () => void;
  onCancel: () => void;
}

function ExportStep(props: ExportStepProps) {
  const warnings = chapterWarnings(props.project.clips);
  const rows = chapterRows(props.project.clips);
  const estimatedBytes = estimateOutputBytes(props.durationSeconds, props.project.outputResolution);
  const progressPercent = Math.round((props.progress?.progress ?? 0) * 100);

  return (
    <section className="step-panel export-panel">
      <div className="section-heading"><div><span className="eyebrow">STEP 4</span><h1>完成動画を書き出す</h1></div></div>
      <div className="export-grid">
        <div className="export-settings">
          <div className="settings-card">
            <h2>解像度</h2>
            <div className="resolution-options">
              {(["1080p", "1440p"] as Resolution[]).map((resolution) => (
                <button key={resolution} className={props.project.outputResolution === resolution ? "selected" : ""} onClick={() => props.onResolution(resolution)} disabled={Boolean(props.renderJobId)}>
                  <strong>{resolution}</strong><span>{resolution === "1080p" ? "1920×1080・15Mbps" : "2560×1440・30Mbps"}</span>
                </button>
              ))}
            </div>
          </div>
          <div className="settings-card">
            <h2>保存先</h2>
            <div className="folder-picker"><input readOnly value={props.outputDirectory} placeholder="保存先フォルダーを選択" /><button className="secondary" onClick={props.onChooseDirectory} disabled={Boolean(props.renderJobId)}>選択</button></div>
            <ul className="output-file-list">
              <li><span>動画</span><code>{safeEventName(props.project.eventName)}.mp4</code></li>
              <li><span>チャプター</span><code>{safeEventName(props.project.eventName)}_チャプター.txt</code></li>
              {props.project.thumbnail && <li><span>サムネイル</span><code>{safeEventName(props.project.eventName)}_サムネイル.jpg</code></li>}
            </ul>
          </div>
          <div className="settings-card summary-stats">
            <div><span>バンド数</span><strong>{bandCount(props.project.clips)}</strong></div>
            <div><span>完成時間</span><strong>{formatChapterTime(props.durationSeconds)}</strong></div>
            <div><span>推定容量</span><strong>{formatBytes(estimatedBytes)}</strong></div>
            <div><span>音声</span><strong>AAC 384kbps</strong></div>
          </div>
        </div>

        <aside className="chapter-preview">
          <div className="chapter-header"><h2>チャプタープレビュー</h2></div>
          <pre>{rows.map((row) => `${formatChapterTime(row.seconds)} ${row.text}`).join("\r\n") || "動画を読み込んでください"}</pre>
          {warnings.map((warning) => <p className="warning-text" key={warning}>⚠ {warning}</p>)}
        </aside>
      </div>

      {props.renderJobId && props.progress && (
        <div className="render-card">
          <div className="render-status"><div><strong>{props.progress.message}</strong><small>{props.progress.encoder ? `使用エンコーダー: ${props.progress.encoder}` : "GPUを確認しています"}</small></div><strong>{progressPercent}%</strong></div>
          <div className="progress-track"><div style={{ width: `${progressPercent}%` }} /></div>
          <div className="render-meta"><span>経過 {formatChapterTime(props.progress.elapsedSeconds)}</span><span>残り {props.progress.etaSeconds == null ? "計算中" : formatChapterTime(props.progress.etaSeconds)}</span></div>
          <button className="danger" onClick={props.onCancel}>書き出しをキャンセル</button>
        </div>
      )}

      {props.result?.status === "completed" && props.result.outputPaths && (
        <div className="success-card"><strong>✓ 書き出し完了</strong><span>{props.result.outputPaths.video}</span></div>
      )}

      <div className="step-footer export-footer">
        <button className="primary large" onClick={props.onStart} disabled={Boolean(props.renderJobId)}>書き出しを開始</button>
      </div>
    </section>
  );
}
