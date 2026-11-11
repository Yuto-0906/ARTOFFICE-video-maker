import { useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { ProjectV1 } from "../types";
import { bandCount, clipGroups, duplicateOrders, formatChapterTime, isBlockingImportError } from "../utils";
import { ArrowDownIcon, ArrowUpIcon, ChevronRightIcon, CloseIcon, FilePlusIcon, FolderPlusIcon, GripIcon, LinkIcon, ScissorsIcon } from "../icons";

interface ImportStepProps {
  project: ProjectV1;
  busy: boolean;
  onEventName: (value: string) => void;
  onChooseFiles: () => void;
  onChooseFolder: () => void;
  onRelink: () => void;
  onBandName: (id: string, value: string) => void;
  onRemoveClip: (id: string) => void;
  onSetJoin: (id: string, joined: boolean) => void;
  onMoveDirection: (id: string, direction: -1 | 1) => void;
  onMove: (sourceId: string, targetId: string) => void;
  onEdit: (id: string) => void;
  onNext: () => void;
}

export default function ImportStep(props: ImportStepProps) {
  const { project } = props;
  const groups = clipGroups(project.clips);
  const duplicates = duplicateOrders(project.clips);
  const hasMissing = project.clips.some(isBlockingImportError);
  const dragId = useRef<string | null>(null);
  const [dragging, setDragging] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<string | null>(null);

  const positions = new Map<string, { groupIndex: number; partIndex: number }>();
  groups.forEach((group, groupIndex) => group.forEach((clip, partIndex) => positions.set(clip.id, { groupIndex, partIndex })));

  function clipIdAt(x: number, y: number): string | null {
    return document.elementFromPoint(x, y)?.closest<HTMLElement>("[data-clip-id]")?.dataset.clipId ?? null;
  }

  function beginDrag(event: ReactPointerEvent<HTMLElement>, id: string) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragId.current = id;
    setDragging(id);
    setDropTarget(id);
  }

  function endDrag(event: ReactPointerEvent<HTMLElement>, cancelled = false) {
    const source = dragId.current;
    const target = cancelled ? null : clipIdAt(event.clientX, event.clientY);
    dragId.current = null;
    setDragging(null);
    setDropTarget(null);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    if (source && target) props.onMove(source, target);
  }

  return (
    <section className="page">
      <div className="page-head">
        <label className="event-name">
          <span>イベント名</span>
          <input
            value={project.eventName}
            placeholder="例：2026 秋ライブ"
            onChange={(event) => props.onEventName(event.target.value)}
          />
          <small>完成動画のファイル名になります</small>
        </label>
        <div className="actions">
          <button className="secondary" onClick={props.onChooseFiles} disabled={props.busy}><FilePlusIcon />ファイルを追加</button>
          <button className="primary" onClick={props.onChooseFolder} disabled={props.busy}><FolderPlusIcon />フォルダーから追加</button>
        </div>
      </div>

      {project.clips.length === 0 ? (
        <div className="dropzone">
          <FolderPlusIcon size={36} />
          <h2>ライブの動画をここにドロップ</h2>
          <p>フォルダーごとドロップすると，中の動画をまとめて追加します。<br />ファイル名の先頭の番号（例：<code>01_バンド名.mp4</code>）を出演順として使います。</p>
          <div className="actions">
            <button className="secondary" onClick={props.onChooseFiles} disabled={props.busy}>ファイルを選ぶ</button>
            <button className="primary" onClick={props.onChooseFolder} disabled={props.busy}>フォルダーを選ぶ</button>
          </div>
        </div>
      ) : (
        <div className="panel clip-list">
          <div className="list-head">
            <span>{bandCount(project.clips)}バンド・{project.clips.length}本</span>
            <span className="muted">左端をドラッグして並べ替え</span>
            {hasMissing && <button className="secondary small" onClick={props.onRelink}>見つからない動画を探す…</button>}
          </div>
          <ol className="rows">
            {project.clips.map((clip, index) => {
              const position = positions.get(clip.id)!;
              const joined = position.partIndex > 0;
              const blocking = isBlockingImportError(clip);
              const problem = blocking ? clip.importError : !clip.media.hasAudio ? "音声が入っていません" : null;
              const duplicate = !joined && duplicates.has(clip.order);
              const trimmed = clip.inFrame > 0 || clip.outFrameExclusive < clip.media.frameCount;
              const keptSeconds = (clip.outFrameExclusive - clip.inFrame) * clip.media.fps.denominator / clip.media.fps.numerator;
              const fps = clip.media.fps.numerator / clip.media.fps.denominator;
              return (
                <li
                  key={clip.id}
                  data-clip-id={clip.id}
                  className={[
                    "row",
                    joined ? "is-part" : "",
                    dragging === clip.id ? "is-dragging" : "",
                    dropTarget === clip.id && dragging !== clip.id ? "is-drop-target" : "",
                    problem ? "has-problem" : "",
                  ].join(" ")}
                >
                  <span
                    className="grip"
                    title="ドラッグして並べ替え"
                    onPointerDown={(event) => beginDrag(event, clip.id)}
                    onPointerMove={(event) => { if (dragId.current) setDropTarget(clipIdAt(event.clientX, event.clientY)); }}
                    onPointerUp={(event) => endDrag(event)}
                    onPointerCancel={(event) => endDrag(event, true)}
                  ><GripIcon size={16} /></span>
                  <span className={`order ${duplicate ? "is-duplicate" : ""}`} title={duplicate ? "同じ番号の動画があります。並べ替えて確認してください" : undefined}>
                    {joined ? <LinkIcon size={14} /> : position.groupIndex + 1}
                  </span>
                  <div className="name">
                    {joined ? (
                      <span className="part-label">{clip.bandName} の続き（{position.partIndex + 1}本目）</span>
                    ) : (
                      <input
                        value={clip.bandName}
                        onChange={(event) => props.onBandName(clip.id, event.target.value)}
                        aria-label={`${position.groupIndex + 1}番目のバンド名`}
                        placeholder="バンド名"
                      />
                    )}
                    <small title={clip.sourcePath}>
                      {clip.sourceFileName}
                      <span>{formatChapterTime(clip.media.durationSeconds)}</span>
                      <span>{clip.media.width}×{clip.media.height}</span>
                      <span>{Number(fps.toFixed(2))}fps</span>
                      {trimmed && <span className="tag">カット後 {formatChapterTime(keptSeconds)}</span>}
                    </small>
                    {problem && <small className="problem">{problem}</small>}
                  </div>
                  {index > 0 ? (
                    <label className="join" title="1バンドの演奏が複数のファイルに分かれているときに使います">
                      <input type="checkbox" checked={joined} onChange={(event) => props.onSetJoin(clip.id, event.target.checked)} />
                      前の動画の続き
                    </label>
                  ) : <span />}
                  <div className="row-actions">
                    <button className="icon" onClick={() => props.onEdit(clip.id)} title="カットする" aria-label={`${clip.bandName}をカット`}><ScissorsIcon size={16} /></button>
                    <button className="icon" onClick={() => props.onMoveDirection(clip.id, -1)} disabled={position.groupIndex === 0} title="1つ前へ" aria-label={`${clip.bandName}を前へ`}><ArrowUpIcon size={16} /></button>
                    <button className="icon" onClick={() => props.onMoveDirection(clip.id, 1)} disabled={position.groupIndex === groups.length - 1} title="1つ後ろへ" aria-label={`${clip.bandName}を後ろへ`}><ArrowDownIcon size={16} /></button>
                    <button className="icon danger-hover" onClick={() => props.onRemoveClip(clip.id)} title="一覧から外す（元のファイルは消えません）" aria-label={`${clip.bandName}を外す`}><CloseIcon size={16} /></button>
                  </div>
                </li>
              );
            })}
          </ol>
        </div>
      )}

      <footer className="page-foot">
        <button className="primary" onClick={props.onNext} disabled={project.clips.length === 0}>カットへ<ChevronRightIcon /></button>
      </footer>
    </section>
  );
}
