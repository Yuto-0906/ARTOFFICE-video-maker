import { useEffect, useImperativeHandle, useRef, useState, type PointerEvent as ReactPointerEvent, type RefObject } from "react";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import type { ClipV1 } from "../types";
import { clipDurationSeconds, clipGroups, formatChapterTime, formatClock, frameToSeconds, parseClock, rulerStep, secondsToFrame } from "../utils";
import { errorMessage, isTypingTarget } from "../shared";
import {
  CheckIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  ExpandIcon,
  FrameBackIcon,
  FrameForwardIcon,
  MuteIcon,
  PauseIcon,
  PlayIcon,
  ToEndIcon,
  ToStartIcon,
  VolumeIcon,
} from "../icons";

// ---------------------------------------------------------------------------
// 動画プレーヤー
// 標準で再生できない動画は，表示位置の30秒分だけ再生用ファイルを作って再生する。
// ---------------------------------------------------------------------------

interface PlayerHandle {
  seek: (seconds: number) => void;
  /** ドラッグ中の位置を表示する。直接再生できる動画だけ映像も追従する */
  scrub: (seconds: number) => void;
  beginScrub: () => void;
  toggle: () => void;
  setVolume: (volume: number, muted: boolean) => void;
}
interface PreparedPreview { path: string; startSeconds: number; endSeconds: number }
interface PreviewVideoProps {
  sourcePath: string;
  preferPreview: boolean;
  playerRef: RefObject<PlayerHandle | null>;
  startSeconds: number;
  stopSeconds: number;
  currentTime: number;
  onSeekRequest: (seconds: number) => void;
  onTimeUpdate: (seconds: number) => void;
  onPlayingChange: (playing: boolean) => void;
  onError: (message: string) => void;
}

function PreviewVideo({ sourcePath, preferPreview, playerRef, startSeconds, stopSeconds, currentTime, onSeekRequest, onTimeUpdate, onPlayingChange, onError }: PreviewVideoProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const clientId = useRef(crypto.randomUUID());
  const generation = useRef(0);
  const pending = useRef(startSeconds);
  const seekTarget = useRef<number | null>(startSeconds);
  const resume = useRef(false);
  const [needsPreview, setNeedsPreview] = useState(preferPreview);
  const [windowStart, setWindowStart] = useState(Math.floor(startSeconds / 30) * 30);
  const [preview, setPreview] = useState<PreparedPreview | null>(null);
  const [failed, setFailed] = useState(false);
  const [playing, setPlayingState] = useState(false);

  function setPlaying(value: boolean) {
    setPlayingState(value);
    onPlayingChange(value);
  }

  function toggle() {
    const video = videoRef.current;
    if (!video) return;
    if (!video.paused || resume.current) {
      resume.current = false; video.pause(); setPlaying(false);
    } else if (currentTime >= stopSeconds || currentTime < startSeconds) {
      resume.current = true; setPlaying(true); onSeekRequest(startSeconds);
    } else if (!video.readyState || seekTarget.current !== null) {
      resume.current = true; setPlaying(true);
    } else {
      void video.play().catch((reason) => onError(errorMessage(reason)));
    }
  }

  function seek(seconds: number) {
    pending.current = seconds;
    seekTarget.current = seconds;
    const video = videoRef.current;
    if (seconds < startSeconds || seconds >= stopSeconds) {
      resume.current = false; video?.pause(); setPlaying(false);
    }
    if (!needsPreview || (preview && seconds >= preview.startSeconds && seconds < preview.endSeconds)) {
      if (video?.readyState) video.currentTime = Math.max(0, seconds - (needsPreview ? preview!.startSeconds : 0));
    } else {
      resume.current = resume.current || Boolean(video && !video.paused);
      video?.pause();
      setPreview(null);
      setWindowStart(Math.floor(seconds / 30) * 30);
    }
  }

  useImperativeHandle(playerRef, () => ({
    seek,
    toggle,
    scrub(seconds) {
      const video = videoRef.current;
      if (!needsPreview && video?.readyState) video.currentTime = seconds;
    },
    beginScrub() {
      const video = videoRef.current;
      resume.current = resume.current || Boolean(video && !video.paused);
      video?.pause();
    },
    setVolume(volume, muted) {
      const video = videoRef.current;
      if (video) { video.volume = volume; video.muted = muted; }
    },
  }));

  function finishSeek() {
    const video = videoRef.current;
    if (!video || video.readyState < 2 || video.seeking || video.currentSrc !== video.src) return;
    const time = video.currentTime + (needsPreview ? preview?.startSeconds ?? 0 : 0);
    if (seekTarget.current !== null && Math.abs(time - seekTarget.current) > 0.001) return;
    seekTarget.current = null;
    if (resume.current) { resume.current = false; void video.play().catch(() => {}); }
  }

  useEffect(() => {
    if (!needsPreview) return;
    let active = true;
    const current = ++generation.current;
    setFailed(false);
    invoke<PreparedPreview>("prepare_video_preview", { sourcePath, seconds: windowStart, clientId: clientId.current, generation: current }).then((result) => {
      if (active) setPreview(result);
    }).catch((reason) => {
      if (active) { setFailed(true); onError(errorMessage(reason)); }
    });
    return () => {
      active = false;
      void invoke("cancel_video_preview", { clientId: clientId.current, generation: current });
    };
  }, [needsPreview, sourcePath, windowStart]);

  return <>
    <video ref={videoRef}
      src={needsPreview ? (preview ? convertFileSrc(preview.path) : undefined) : convertFileSrc(sourcePath)}
      preload="metadata"
      onClick={toggle}
      onPlay={() => setPlaying(true)}
      onPause={() => { if (!resume.current) setPlaying(false); }}
      onLoadedMetadata={() => {
        if (needsPreview && !preview) return;
        const video = videoRef.current!;
        const target = pending.current - (needsPreview ? preview!.startSeconds : 0);
        if (target < 0 || target > video.duration) return;
        video.currentTime = target;
      }}
      onSeeked={finishSeek}
      onLoadedData={finishSeek}
      onTimeUpdate={(event) => {
        if (needsPreview && !preview) return;
        const video = event.currentTarget;
        finishSeek();
        if (seekTarget.current !== null || video.seeking || video.readyState < 2) return;
        const time = video.currentTime + (needsPreview ? preview?.startSeconds ?? 0 : 0);
        if (!video.paused && time >= stopSeconds) {
          video.pause();
          video.currentTime = Math.max(0, stopSeconds - (needsPreview ? preview?.startSeconds ?? 0 : 0));
          pending.current = stopSeconds;
          onTimeUpdate(stopSeconds);
        } else {
          pending.current = time;
          onTimeUpdate(time);
        }
      }}
      onEnded={() => {
        if (needsPreview && preview && preview.endSeconds < stopSeconds - 0.01) {
          pending.current = preview.endSeconds;
          seekTarget.current = preview.endSeconds;
          resume.current = true;
          setPlaying(true);
          setWindowStart(preview.endSeconds);
          setPreview(null);
        }
      }}
      onError={() => {
        if (!needsPreview) { setWindowStart(Math.floor(pending.current / 30) * 30); setNeedsPreview(true); }
        else if (preview) { setFailed(true); onError("この位置の映像を表示できませんでした。"); }
      }}
    />
    {needsPreview && !preview && <div className="video-status" role="status">{failed ? "この位置の映像を表示できませんでした" : "読み込み中…"}</div>}
    {!playing && (needsPreview ? preview : true) && <button className="big-play" onClick={toggle} aria-label="再生"><PlayIcon size={34} /></button>}
  </>;
}

// ---------------------------------------------------------------------------
// 時間軸：再生位置の移動と，開始・終了位置のドラッグを1本で行う
// ---------------------------------------------------------------------------

type DragMode = "seek" | "in" | "out";

function shortTime(seconds: number, long: boolean): string {
  const full = formatChapterTime(seconds);
  return long ? full : full.replace(/^0:/, "");
}

interface TimelineProps {
  duration: number;
  inSeconds: number;
  outSeconds: number;
  current: number;
  onScrubStart: () => void;
  onScrub: (seconds: number) => void;
  onSeek: (seconds: number) => void;
  onTrim: (mode: "in" | "out", seconds: number) => void;
}

function Timeline({ duration, inSeconds, outSeconds, current, onScrubStart, onScrub, onSeek, onTrim }: TimelineProps) {
  const trackRef = useRef<HTMLDivElement>(null);
  const [drag, setDragState] = useState<{ mode: DragMode; time: number } | null>(null);
  // ポインターイベントは再描画より速く届くことがあるため，最新の状態を参照で持つ。
  const dragRef = useRef<{ mode: DragMode; time: number } | null>(null);
  const setDrag = (value: { mode: DragMode; time: number } | null) => { dragRef.current = value; setDragState(value); };
  const [hoverHandle, setHoverHandle] = useState<DragMode | null>(null);
  const safeDuration = Math.max(0.001, duration);
  const percent = (seconds: number) => `${Math.min(100, Math.max(0, (seconds / safeDuration) * 100))}%`;

  function timeAt(clientX: number): number {
    const rect = trackRef.current!.getBoundingClientRect();
    return Math.min(1, Math.max(0, (clientX - rect.left) / rect.width)) * safeDuration;
  }

  function modeAt(clientX: number): DragMode {
    const rect = trackRef.current!.getBoundingClientRect();
    const x = clientX - rect.left;
    const inDistance = Math.abs(x - (inSeconds / safeDuration) * rect.width);
    const outDistance = Math.abs(x - (outSeconds / safeDuration) * rect.width);
    if (Math.min(inDistance, outDistance) > 9) return "seek";
    return inDistance < outDistance ? "in" : "out";
  }

  function apply(mode: DragMode, time: number) {
    setDrag({ mode, time });
    if (mode !== "seek") onTrim(mode, time);
    onScrub(time);
  }

  function onPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    onScrubStart();
    apply(modeAt(event.clientX), timeAt(event.clientX));
  }

  function onPointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (dragRef.current) apply(dragRef.current.mode, timeAt(event.clientX));
    else {
      const mode = modeAt(event.clientX);
      setHoverHandle(mode === "seek" ? null : mode);
    }
  }

  function finish(event: ReactPointerEvent<HTMLDivElement>) {
    const current = dragRef.current;
    if (!current) return;
    const time = timeAt(event.clientX);
    if (current.mode !== "seek") onTrim(current.mode, time);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    setDrag(null);
    onSeek(time);
  }

  const step = rulerStep(duration);
  const ticks: number[] = [];
  for (let t = 0; t <= duration; t += step) ticks.push(t);
  const long = duration >= 3600;
  const playhead = drag?.mode === "seek" ? drag.time : current;

  return (
    <div className="timeline">
      <div
        ref={trackRef}
        className={`timeline-track ${hoverHandle || drag?.mode === "in" || drag?.mode === "out" ? "on-handle" : ""}`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={finish}
        onPointerCancel={finish}
        onPointerLeave={() => setHoverHandle(null)}
        role="group"
        aria-label="時間軸。クリックで移動，両端のつまみで開始・終了を調整"
      >
        <div className="timeline-cut" style={{ left: 0, width: percent(inSeconds) }} />
        <div className="timeline-cut" style={{ left: percent(outSeconds), right: 0 }} />
        <div className="timeline-keep" style={{ left: percent(inSeconds), width: `calc(${percent(outSeconds)} - ${percent(inSeconds)})` }} />
        <div className={`timeline-handle in ${drag?.mode === "in" || hoverHandle === "in" ? "hot" : ""}`} style={{ left: percent(inSeconds) }} />
        <div className={`timeline-handle out ${drag?.mode === "out" || hoverHandle === "out" ? "hot" : ""}`} style={{ left: percent(outSeconds) }} />
        <div className="timeline-playhead" style={{ left: percent(playhead) }} />
        {drag && <div className="timeline-bubble" style={{ left: percent(drag.time) }}>{formatClock(drag.time)}</div>}
      </div>
      <div className="timeline-ruler" aria-hidden="true">
        {ticks.map((tick) => <span key={tick} style={{ left: percent(tick) }}>{shortTime(tick, long)}</span>)}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 時刻入力（Enterで確定，Escで取り消し）
// ---------------------------------------------------------------------------

function TimeField({ label, seconds, onCommit }: { label: string; seconds: number; onCommit: (seconds: number) => void }) {
  const formatted = formatClock(seconds);
  const [text, setText] = useState(formatted);
  const [invalid, setInvalid] = useState(false);
  useEffect(() => { setText(formatted); setInvalid(false); }, [formatted]);

  function commit() {
    if (text === formatted) return;
    const parsed = parseClock(text);
    if (parsed === null) { setInvalid(true); return; }
    setInvalid(false);
    onCommit(parsed);
  }

  return (
    <input
      className={`time-field ${invalid ? "is-invalid" : ""}`}
      value={text}
      aria-label={label}
      title={invalid ? "時:分:秒.ミリ秒 の形で入力してください（例 0:01:23.500）" : `${label}（Enterで確定）`}
      onChange={(event) => { setText(event.target.value); setInvalid(false); }}
      onBlur={commit}
      onKeyDown={(event) => {
        if (event.key === "Enter") { commit(); event.currentTarget.blur(); }
        else if (event.key === "Escape") { setText(formatted); setInvalid(false); event.currentTarget.blur(); }
      }}
    />
  );
}

// ---------------------------------------------------------------------------
// カット画面
// ---------------------------------------------------------------------------

interface TrimStepProps {
  clips: ClipV1[];
  selected: ClipV1;
  onSelect: (id: string) => void;
  onUpdate: (id: string, updater: (clip: ClipV1) => ClipV1, key?: string) => void;
  onNext: () => void;
  onError: (message: string) => void;
}

export default function TrimStep({ clips, selected, onSelect, onUpdate, onNext, onError }: TrimStepProps) {
  const playerRef = useRef<PlayerHandle>(null);
  const playerBoxRef = useRef<HTMLDivElement>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const fps = selected.media.fps;
  const frame = fps.denominator / fps.numerator;
  const inSeconds = frameToSeconds(selected.inFrame, fps);
  const outSeconds = frameToSeconds(selected.outFrameExclusive, fps);
  const lastFrameSeconds = frameToSeconds(Math.max(0, selected.media.frameCount - 1), fps);
  const titleTime = currentTime - inSeconds;
  const titleOpacity = selected.joinWithPrevious || titleTime < 0 || titleTime >= 5 ? 0 : titleTime < 0.5 ? titleTime / 0.5 : titleTime < 4.5 ? 1 : (5 - titleTime) / 0.5;
  const index = clips.findIndex((clip) => clip.id === selected.id);

  const groups = clipGroups(clips);
  const labels = new Map<string, string>();
  groups.forEach((group, bandIndex) => group.forEach((clip, partIndex) => {
    labels.set(clip.id, group.length > 1 ? `${bandIndex + 1}-${partIndex + 1}` : String(bandIndex + 1));
  }));

  useEffect(() => {
    setCurrentTime(inSeconds);
    playerRef.current?.seek(inSeconds);
    // 選んだ動画が変わったときだけ開始位置へ移動する。
  }, [selected.id]);

  useEffect(() => { playerRef.current?.setVolume(volume, muted); }, [volume, muted, selected.sourcePath]);
  useEffect(() => { setPlaying(false); }, [selected.sourcePath]);

  function seek(seconds: number) {
    const clamped = Math.min(lastFrameSeconds, Math.max(0, seconds));
    playerRef.current?.seek(clamped);
    setCurrentTime(clamped);
  }

  function setIn(seconds: number, key?: string) {
    onUpdate(selected.id, (clip) => ({ ...clip, inFrame: Math.min(clip.outFrameExclusive - 1, secondsToFrame(seconds, clip.media.fps)) }), key);
  }

  function setOut(seconds: number, key?: string) {
    onUpdate(selected.id, (clip) => ({ ...clip, outFrameExclusive: Math.min(clip.media.frameCount, Math.max(clip.inFrame + 1, secondsToFrame(seconds, clip.media.fps))) }), key);
  }

  function goToClip(offset: number) {
    const target = clips[index + offset];
    if (target) onSelect(target.id);
  }

  function toggleFullscreen() {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void playerBoxRef.current?.requestFullscreen().catch(() => onError("全画面表示に切り替えられませんでした。"));
  }

  // 最新の状態を参照するため，毎回登録し直す。
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.ctrlKey || event.metaKey || event.altKey || isTypingTarget(event.target)) return;
      const big = event.shiftKey ? 1 : frame;
      let handled = true;
      switch (event.key) {
        case " ":
        case "k":
        case "K":
          playerRef.current?.toggle();
          if (event.target instanceof HTMLElement && event.target.tagName === "BUTTON") event.target.blur();
          break;
        case "ArrowLeft": seek(currentTime - big); break;
        case "ArrowRight": seek(currentTime + big); break;
        case "i": case "I": setIn(currentTime); break;
        case "o": case "O": setOut(currentTime); break;
        case "Home": seek(inSeconds); break;
        case "End": seek(Math.max(inSeconds, outSeconds - 3)); break;
        case "ArrowUp": case "PageUp": goToClip(-1); break;
        case "ArrowDown": case "PageDown": goToClip(1); break;
        case "f": case "F": toggleFullscreen(); break;
        default: handled = false;
      }
      if (handled) event.preventDefault();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  return (
    <section className="trim">
      <aside className="trim-list" aria-label="動画の一覧">
        {clips.map((clip) => {
          const trimmed = clip.inFrame > 0 || clip.outFrameExclusive < clip.media.frameCount;
          return (
            <button key={clip.id} className={clip.id === selected.id ? "selected" : ""} onClick={() => onSelect(clip.id)} aria-current={clip.id === selected.id}>
              <span className="trim-list-no">{labels.get(clip.id)}</span>
              <span className="trim-list-text">
                <strong>{clip.bandName}</strong>
                <small>{formatChapterTime(clipDurationSeconds(clip))}</small>
              </span>
              {trimmed && <span className="trim-list-done" title="カット済み"><CheckIcon size={14} /></span>}
            </button>
          );
        })}
      </aside>

      <div className="trim-main">
        <div className="trim-head">
          <h1>{selected.bandName}{selected.joinWithPrevious ? <small>（続き）</small> : null}</h1>
          <div className="trim-nav">
            <button className="icon" onClick={() => goToClip(-1)} disabled={index <= 0} title="前の動画（↑）" aria-label="前の動画"><ChevronLeftIcon /></button>
            <span>{index + 1} / {clips.length}</span>
            <button className="icon" onClick={() => goToClip(1)} disabled={index >= clips.length - 1} title="次の動画（↓）" aria-label="次の動画"><ChevronRightIcon /></button>
          </div>
        </div>

        <div className="player" ref={playerBoxRef}>
          <div className="video-stage">
            <PreviewVideo
              key={selected.sourcePath}
              playerRef={playerRef}
              sourcePath={selected.sourcePath}
              preferPreview={!/\.(mp4|mov)$/i.test(selected.sourcePath) || selected.media.videoCodec !== "h264" || selected.media.pixelFormat !== "yuv420p" || (selected.media.hasAudio && selected.media.audioCodec !== "aac")}
              onError={onError}
              startSeconds={inSeconds}
              stopSeconds={outSeconds}
              currentTime={currentTime}
              onSeekRequest={seek}
              onTimeUpdate={setCurrentTime}
              onPlayingChange={setPlaying}
            />
            <div className="band-title-preview" style={{ opacity: Math.max(0, Math.min(1, titleOpacity)) }}>{selected.bandName}</div>
          </div>

          <div className="transport">
            <div className="transport-buttons">
              <button className="icon" onClick={() => seek(inSeconds)} title="開始位置へ（Home）" aria-label="開始位置へ"><ToStartIcon /></button>
              <button className="icon" onClick={() => seek(currentTime - frame)} title="1フレーム戻る（←）" aria-label="1フレーム戻る"><FrameBackIcon /></button>
              <button className="icon play" onClick={() => playerRef.current?.toggle()} title={`${playing ? "一時停止" : "再生"}（Space）`} aria-label={playing ? "一時停止" : "再生"}>
                {playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
              </button>
              <button className="icon" onClick={() => seek(currentTime + frame)} title="1フレーム進む（→）" aria-label="1フレーム進む"><FrameForwardIcon /></button>
              <button className="icon" onClick={() => seek(Math.max(inSeconds, outSeconds - 3))} title="終了位置の3秒前へ（End）" aria-label="終了位置の3秒前へ"><ToEndIcon /></button>
            </div>
            <span className="clock" role="timer">{formatClock(currentTime)}<span> / {formatChapterTime(selected.media.durationSeconds)}</span></span>
            <div className="transport-right">
              <button className="icon" onClick={() => setMuted(!muted)} title={muted ? "音を出す" : "消音"} aria-label={muted ? "音を出す" : "消音"}>{muted || volume === 0 ? <MuteIcon /> : <VolumeIcon />}</button>
              <input className="volume" type="range" min={0} max={1} step={0.05} value={muted ? 0 : volume} aria-label="音量"
                onChange={(event) => { setVolume(Number(event.target.value)); setMuted(false); }} />
              <button className="icon" onClick={toggleFullscreen} title="全画面（F）" aria-label="全画面"><ExpandIcon /></button>
            </div>
          </div>

          <Timeline
            duration={selected.media.durationSeconds}
            inSeconds={inSeconds}
            outSeconds={outSeconds}
            current={currentTime}
            onScrubStart={() => playerRef.current?.beginScrub()}
            onScrub={(seconds) => { playerRef.current?.scrub(seconds); }}
            onSeek={seek}
            onTrim={(mode, seconds) => (mode === "in" ? setIn(seconds, `trim:${selected.id}:in`) : setOut(seconds, `trim:${selected.id}:out`))}
          />
        </div>

        <div className="marks">
          <div className="mark">
            <span>開始</span>
            <TimeField label="開始位置" seconds={inSeconds} onCommit={(seconds) => setIn(seconds)} />
            <button className="secondary" onClick={() => setIn(currentTime)} title="キー：I">ここから開始</button>
          </div>
          <div className="kept">
            <span>残す長さ</span>
            <strong>{formatChapterTime(clipDurationSeconds(selected))}</strong>
          </div>
          <div className="mark end">
            <button className="secondary" onClick={() => setOut(currentTime)} title="キー：O">ここで終了</button>
            <TimeField label="終了位置" seconds={outSeconds} onCommit={(seconds) => setOut(seconds)} />
            <span>終了</span>
          </div>
        </div>

        <footer className="page-foot">
          <p className="keys">
            <kbd>Space</kbd>再生・停止　<kbd>←</kbd><kbd>→</kbd>1フレーム　<kbd>Shift</kbd>+<kbd>←</kbd><kbd>→</kbd>1秒　<kbd>I</kbd>開始　<kbd>O</kbd>終了　<kbd>↑</kbd><kbd>↓</kbd>前後の動画
          </p>
          <div className="actions">
            {index < clips.length - 1 && <button className="secondary" onClick={() => goToClip(1)}>次の動画<ChevronRightIcon /></button>}
            <button className={index < clips.length - 1 ? "quiet" : "primary"} onClick={onNext}>サムネイルへ<ChevronRightIcon /></button>
          </div>
        </footer>
      </div>
    </section>
  );
}
