import type { FrameRate, ProjectV1, RenderFinished, RenderProgress, Resolution } from "../types";
import { bandCount, chapterRows, chapterWarnings, estimateOutputBytes, formatBytes, formatChapterTime, projectDurationSeconds } from "../utils";
import { copyText, errorMessage, safeEventName, type Issue, type Step } from "../shared";
import { AlertIcon, CheckIcon, CopyIcon, ExportIcon, FolderOpenIcon } from "../icons";

interface ExportStepProps {
  project: ProjectV1;
  outputDirectory: string;
  issues: Issue[];
  renderJobId: string | null;
  progress: RenderProgress | null;
  result: RenderFinished | null;
  onEventName: (value: string) => void;
  onResolution: (value: Resolution) => void;
  onFrameRate: (value: FrameRate) => void;
  onChooseDirectory: () => void;
  onGoToStep: (step: Step) => void;
  onStart: () => void;
  onCancel: () => void;
  onReveal: (path: string) => void;
  onToast: (text: string) => void;
  onError: (text: string) => void;
}

const FRAME_RATES = ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"] as const;

export default function ExportStep(props: ExportStepProps) {
  const { project } = props;
  const first = project.clips[0]?.media;
  const rendering = Boolean(props.renderJobId);
  const duration = projectDurationSeconds(project.clips);
  const chapters = chapterRows(project.clips).map((row) => `${formatChapterTime(row.seconds)} ${row.text}`).join("\n");
  const warnings = chapterWarnings(project.clips);
  const name = safeEventName(project.eventName);
  const percent = Math.round((props.progress?.progress ?? 0) * 100);
  const completed = props.result?.status === "completed" ? props.result.outputPaths : null;
  const firstFps = first ? Number((first.fps.numerator / first.fps.denominator).toFixed(3)) : null;

  const resolutions: Array<{ id: Resolution; label: string; detail: string }> = [
    { id: "source", label: "元の動画と同じ", detail: first ? `${first.width}×${first.height}` : "" },
    { id: "1080p", label: "1080p", detail: "1920×1080" },
    { id: "1440p", label: "1440p", detail: "2560×1440" },
  ];

  async function copyChapters() {
    try {
      await copyText(chapters);
      props.onToast("チャプターをコピーしました");
    } catch (reason) {
      props.onError(errorMessage(reason));
    }
  }

  return (
    <section className="page export">
      <div className="export-grid">
        <div className="export-main">
          <div className="panel form">
            <label className="field">
              <span>ファイル名</span>
              <div className="with-suffix">
                <input value={project.eventName} placeholder="イベント名" onChange={(event) => props.onEventName(event.target.value)} disabled={rendering} />
                <span>.mp4</span>
              </div>
            </label>

            <div className="field">
              <span>保存先</span>
              <div className="folder-row">
                <span className="path" title={props.outputDirectory}>{props.outputDirectory || "未選択"}</span>
                <button className="secondary" onClick={props.onChooseDirectory} disabled={rendering}>変更…</button>
              </div>
              <small className="muted">
                {name}.mp4・{name}_チャプター.txt{project.thumbnail ? `・${name}_サムネイル.${project.thumbnail.outputFormat ?? "jpg"}` : ""} を保存します
              </small>
            </div>

            <div className="field">
              <span>画質</span>
              <div className="segmented wide" role="radiogroup" aria-label="解像度">
                {resolutions.map((item) => (
                  <button key={item.id} role="radio" aria-checked={project.outputResolution === item.id}
                    className={project.outputResolution === item.id ? "on" : ""}
                    onClick={() => props.onResolution(item.id)} disabled={rendering}>
                    {item.label}<small>{item.detail}</small>
                  </button>
                ))}
              </div>
            </div>

            <label className="field">
              <span>フレームレート</span>
              <select value={project.outputFrameRate ?? "59.94"} onChange={(event) => props.onFrameRate(event.target.value as FrameRate)} disabled={rendering}>
                <option value="source">元の動画と同じ{firstFps ? `（${firstFps}fps）` : ""}</option>
                {FRAME_RATES.map((rate) => <option key={rate} value={rate}>{rate}fps</option>)}
              </select>
            </label>
          </div>

          <dl className="summary">
            <div><dt>長さ</dt><dd>{formatChapterTime(duration)}</dd></div>
            <div><dt>バンド</dt><dd>{bandCount(project.clips)}組</dd></div>
            <div><dt>容量の目安</dt><dd>約{formatBytes(estimateOutputBytes(duration, project.outputResolution, first))}</dd></div>
          </dl>

          {props.issues.length > 0 && !rendering && (
            <div className="panel issues">
              <strong><AlertIcon size={16} />書き出す前に直してください</strong>
              <ul>
                {props.issues.map((issue) => (
                  <li key={issue.text}>
                    {issue.text}
                    {issue.step === "import" && <button className="link" onClick={() => props.onGoToStep("import")}>動画の画面へ</button>}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {rendering && props.progress && (
            <div className="panel progress">
              <div className="progress-head">
                <strong>{props.progress.message}</strong>
                <span>{percent}%</span>
              </div>
              <div className="bar"><div style={{ width: `${percent}%` }} /></div>
              <div className="progress-foot">
                <span className="muted">経過 {formatChapterTime(props.progress.elapsedSeconds)}・残り {props.progress.etaSeconds == null ? "計算中" : `約${formatChapterTime(props.progress.etaSeconds)}`}</span>
                <button className="secondary small" onClick={props.onCancel}>中止</button>
              </div>
            </div>
          )}

          {completed && !rendering && (
            <div className="panel done">
              <CheckIcon size={20} />
              <div>
                <strong>書き出しました</strong>
                <small className="ellipsis" title={completed.video}>{completed.video}</small>
              </div>
              <button className="secondary" onClick={() => props.onReveal(completed.video)}><FolderOpenIcon />フォルダーで表示</button>
            </div>
          )}

          <div className="export-action">
            <button className="primary large" onClick={props.onStart} disabled={rendering || props.issues.length > 0}>
              <ExportIcon />{rendering ? "書き出し中…" : "書き出す"}
            </button>
          </div>
        </div>

        <aside className="panel chapters">
          <div className="chapters-head">
            <strong>YouTube用チャプター</strong>
            <button className="secondary small" onClick={copyChapters} disabled={!chapters}><CopyIcon size={15} />コピー</button>
          </div>
          <pre>{chapters || "動画を追加すると表示されます"}</pre>
          {warnings.map((warning) => <p className="warn" key={warning}>{warning}</p>)}
        </aside>
      </div>
    </section>
  );
}
