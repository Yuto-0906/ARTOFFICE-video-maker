import { describe, expect, it } from "vitest";
import type { ClipV1 } from "./types";
import {
  chapterRows,
  chapterWarnings,
  duplicateOrders,
  frameToSeconds,
  formatChapterTime,
  parseClock,
  parseVideoFileName,
  projectDurationSeconds,
  secondsToFrame,
  sortClipsByOrder,
} from "./utils";

const clip = (name: string, seconds: number): ClipV1 => ({
  id: name,
  sourcePath: `C:\\動画\\1_${name}.MP4`,
  sourceFileName: `1_${name}.MP4`,
  fingerprint: { size: 1, modifiedUnixMs: 1 },
  order: 1,
  bandName: name,
  inFrame: 0,
  outFrameExclusive: Math.round(seconds * 60000 / 1001),
  media: {
    durationSeconds: seconds,
    width: 1920,
    height: 1080,
    fps: { numerator: 60000, denominator: 1001 },
    frameCount: Math.round(seconds * 60000 / 1001),
    videoCodec: "h264",
    pixelFormat: "yuv420p",
    colorSpace: "bt709",
    audioCodec: "aac",
    sampleRate: 48000,
    channels: 2,
    hasAudio: true,
    needsConversion: false,
    conversionReasons: [],
  },
});

describe("parseVideoFileName", () => {
  it("最初のアンダースコアだけを区切りにする", () => {
    expect(parseVideoFileName("12_Mrs._GREEN_APPLE.MP4")).toEqual({ order: 12, bandName: "Mrs._GREEN_APPLE" });
    expect(parseVideoFileName("2_東京 事変_コピー.MP4")).toEqual({ order: 2, bandName: "東京 事変_コピー" });
  });

  it("不正な名前を拒否する", () => {
    expect(parseVideoFileName("MOSHIMO.MP4")).toBeNull();
    expect(parseVideoFileName("A_MOSHIMO.MP4")).toBeNull();
    expect(parseVideoFileName("0_MOSHIMO.MP4")).toBeNull();
    expect(parseVideoFileName("1_.MP4")).toBeNull();
  });

  it("出演順を文字列順ではなく数値順で並べる", () => {
    const clips = [clip("十番", 10), clip("二番", 10), clip("一番", 10)];
    clips[0].order = 10;
    clips[1].order = 2;
    clips[2].order = 1;
    expect(sortClipsByOrder(clips).map((value) => value.order)).toEqual([1, 2, 10]);
  });

  it("重複する出演順をすべて検出する", () => {
    expect([...duplicateOrders([{ order: 1 }, { order: 2 }, { order: 2 }, { order: 10 }, { order: 10 }])]).toEqual([2, 10]);
  });
});

describe("chapter calculation", () => {
  it("クロスフェード開始を秒単位で切り捨てる", () => {
    const clips = [clip("A", 20.8), clip("B", 30.2), clip("C", 10)];
    expect(chapterRows(clips)).toEqual([
      { seconds: 0, text: "A" },
      { seconds: 20, text: "B" },
      { seconds: 50, text: "C" },
    ]);
    expect(projectDurationSeconds(clips)).toBeCloseTo(60, 1);
  });

  it("時刻は必ずH:MM:SSになる", () => {
    expect(formatChapterTime(0)).toBe("0:00:00");
    expect(formatChapterTime(7325.9)).toBe("2:02:05");
  });

  it("YouTubeの章数と最短時間の条件を警告する", () => {
    expect(chapterWarnings([clip("A", 8), clip("B", 12)])).toEqual([
      "YouTubeのチャプター表示には3件以上の時刻が必要です。",
      "Aは10秒未満のため，YouTubeでチャプターとして認識されない可能性があります。",
    ]);
  });
});

describe("time entry", () => {
  it("ミリ秒付き時刻を解析する", () => {
    expect(parseClock("1:02:03.250")).toBe(3723.25);
    expect(parseClock("1:99:00")).toBeNull();
  });

  it("59.94fpsのフレーム番号と秒を相互変換する", () => {
    const fps = { numerator: 60000, denominator: 1001 };
    expect(frameToSeconds(600, fps)).toBeCloseTo(10.01, 6);
    expect(secondsToFrame(10.01, fps)).toBe(600);
  });
});
