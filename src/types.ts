export type Resolution = "1080p" | "1440p";

export interface Rational {
  numerator: number;
  denominator: number;
}
export interface MediaInfo {
  durationSeconds: number;
  width: number;
  height: number;
  fps: Rational;
  frameCount: number;
  videoCodec: string;
  pixelFormat: string;
  colorSpace: string | null;
  audioCodec: string | null;
  sampleRate: number | null;
  channels: number | null;
  hasAudio: boolean;
  needsConversion: boolean;
  conversionReasons: string[];
}

export interface SourceFingerprint {
  size: number;
  modifiedUnixMs: number;
}

export interface ClipV1 {
  id: string;
  sourcePath: string;
  sourceFileName: string;
  fingerprint: SourceFingerprint;
  order: number;
  bandName: string;
  inFrame: number;
  outFrameExclusive: number;
  media: MediaInfo;
  /** 前の動画と同じバンドの続きとして，クロスフェードなしで直結する。 */
  joinWithPrevious?: boolean;
  importError?: string;
}

export interface CropRectNormalized {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ThumbnailV1 {
  sourcePath: string;
  previewPath: string;
  sourceWidth: number;
  sourceHeight: number;
  exifOrientation: number;
  crop: CropRectNormalized;
  zoom: number;
}

export interface ProjectV1 {
  schemaVersion: 1;
  appVersion: "0.1.0" | "0.2.0" | "0.2.1";
  eventName: string;
  clips: ClipV1[];
  outputResolution: Resolution;
  transitionMs: 500;
  thumbnail: ThumbnailV1 | null;
}

export interface ParsedFileName {
  order: number;
  bandName: string;
}

export interface ProbeResult {
  path: string;
  fileName: string;
  fingerprint: SourceFingerprint;
  media: MediaInfo | null;
  error: string | null;
}

export interface PreparedThumbnail {
  sourcePath: string;
  previewPath: string;
  sourceWidth: number;
  sourceHeight: number;
  exifOrientation: number;
}

export interface ToolStatus {
  ffmpegPath: string | null;
  ffprobePath: string | null;
  magickPath: string | null;
  fontPath: string | null;
}

export interface RenderRequest {
  eventName: string;
  outputDirectory: string;
  resolution: Resolution;
  clips: ClipV1[];
  thumbnail: ThumbnailV1 | null;
  overwrite: boolean;
}

export interface OutputPaths {
  video: string;
  chapters: string;
  thumbnail: string | null;
  existing: string[];
}

export interface RenderStarted {
  jobId: string;
}

export interface RenderProgress {
  jobId: string;
  phase: "preparing" | "rendering" | "finalizing";
  progress: number;
  elapsedSeconds: number;
  etaSeconds: number | null;
  encoder: string | null;
  message: string;
}

export interface RenderFinished {
  jobId: string;
  status: "completed" | "cancelled" | "failed";
  encoder: string | null;
  outputPaths: OutputPaths | null;
  error: string | null;
}
