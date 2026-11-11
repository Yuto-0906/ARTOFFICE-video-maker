import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import Cropper, { type Area, type Point } from "react-easy-crop";
import type { ThumbnailV1 } from "../types";
import { basename } from "../utils";
import { ChevronRightIcon, ImageIcon } from "../icons";

interface ThumbnailStepProps {
  thumbnail: ThumbnailV1 | null;
  busy: boolean;
  onChoose: () => void;
  onRemove: () => void;
  onFormat: (format: "jpg" | "png") => void;
  onCropComplete: (area: Area, zoom: number) => void;
  onNext: () => void;
}

export default function ThumbnailStep({ thumbnail, busy, onChoose, onRemove, onFormat, onCropComplete, onNext }: ThumbnailStepProps) {
  const [crop, setCrop] = useState<Point>({ x: 0, y: 0 });
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
    setCrop((current) => Math.abs(current.x - next.x) < 1e-6 && Math.abs(current.y - next.y) < 1e-6 ? current : next);
  }, []);
  const handleZoomChange = useCallback((next: number) => {
    setZoom((current) => Math.abs(current - next) < 1e-6 ? current : next);
  }, []);
  const rememberCrop = useCallback((area: Area) => { croppedAreaRef.current = area; }, []);
  const commitCrop = useCallback(() => {
    if (croppedAreaRef.current) onCropComplete(croppedAreaRef.current, zoom);
  }, [onCropComplete, zoom]);

  return (
    <section className="page">
      <div className="page-head">
        <div>
          <h1>サムネイル</h1>
          <p className="muted">集合写真を16:9に切り抜きます。使わない場合はそのまま次へ進んでください。</p>
        </div>
        {thumbnail && <div className="actions"><button className="secondary" onClick={onChoose} disabled={busy}>写真を変える</button></div>}
      </div>

      {!thumbnail ? (
        <div className="dropzone">
          <ImageIcon size={36} />
          <h2>集合写真をここにドロップ</h2>
          <p>JPEG，PNG，HEIC，WebPなど</p>
          <div className="actions"><button className="primary" onClick={onChoose} disabled={busy}>写真を選ぶ</button></div>
        </div>
      ) : (
        <div className="crop-layout">
          <div className="crop-stage">
            <Cropper
              image={convertFileSrc(thumbnail.previewPath)}
              crop={crop}
              zoom={zoom}
              maxZoom={4}
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
          <aside className="panel crop-side">
            <div className="field">
              <span>写真</span>
              <strong className="ellipsis" title={thumbnail.sourcePath}>{basename(thumbnail.sourcePath)}</strong>
              <small className="muted">{thumbnail.sourceWidth}×{thumbnail.sourceHeight}</small>
            </div>
            <label className="field">
              <span>拡大 <small className="muted">{Math.round(zoom * 100)}%</small></span>
              <input type="range" min={1} max={4} step={0.01} value={zoom}
                onChange={(event) => handleZoomChange(Number(event.target.value))}
                onPointerUp={commitCrop} onKeyUp={commitCrop} onBlur={commitCrop} />
            </label>
            <div className="field">
              <span>形式</span>
              <div className="segmented" role="radiogroup" aria-label="保存形式">
                {(["jpg", "png"] as const).map((format) => (
                  <button key={format} role="radio" aria-checked={(thumbnail.outputFormat ?? "jpg") === format}
                    className={(thumbnail.outputFormat ?? "jpg") === format ? "on" : ""}
                    onClick={() => onFormat(format)} disabled={busy}>
                    {format === "jpg" ? "JPEG" : "PNG"}
                  </button>
                ))}
              </div>
            </div>
            <p className="muted small-text">写真はドラッグで動かし，ホイールで拡大できます。</p>
            <button className="quiet danger-text" onClick={onRemove}>サムネイルを使わない</button>
          </aside>
        </div>
      )}

      <footer className="page-foot">
        <button className="primary" onClick={onNext}>書き出しへ<ChevronRightIcon /></button>
      </footer>
    </section>
  );
}
