import { describe, expect, it } from "vitest";
import type { ClipV1 } from "./types";
import {
  bandCount,
  chapterRows,
  chapterWarnings,
  centeredCropForAspect,
  clipGroups,
  duplicateOrders,
  estimateOutputBytes,
  frameToSeconds,
  formatChapterTime,
  isVideoPath,
  isThumbnailImagePath,
  moveClipGroup,
  parseClock,
  parseVideoFileName,
  projectDurationSeconds,
  renumberClipOrders,
  secondsToFrame,
  sortClipsByOrder,
  validateProject,
} from "./utils";

describe("ドラッグ＆ドロップの対応形式", () => {
  it("動画の大文字・小文字を判定する", () => {
    expect(isVideoPath(String.raw`C:\動画\1_バンド.MP4`)).toBe(true);
    expect(isVideoPath(String.raw`C:\動画\1_バンド.mp4`)).toBe(true);
    ["mkv", "MOV", "webm", "MTS", "m2ts", "AVI", "wmv"].forEach((extension) => {
      expect(isVideoPath(`C:/動画/1_バンド.${extension}`)).toBe(true);
    });
    ["mp3", "txt", "mp4.exe", ""].forEach((extension) => {
      expect(isVideoPath(`C:/動画/1_バンド.${extension}`)).toBe(false);
    });
  });

  it("サムネイル用画像の対応形式を判定する", () => {
    ["jpg", "JPEG", "png", "HEIC", "heif", "webp", "TIF", "tiff", "BMP", "avif", "GIF"].forEach((extension) => {
      expect(isThumbnailImagePath(`C:\\写真\\集合写真.${extension}`)).toBe(true);
    });
    expect(isThumbnailImagePath(String.raw`C:\写真\集合写真.svg`)).toBe(false);
  });
});

describe("thumbnail crop", () => {
  it("2731×1536の画像を中央の16:9へ正規化する", () => {
    const crop = centeredCropForAspect(2731, 1536);
    expect(crop.height).toBe(1);
    expect(crop.width).toBeCloseTo((16 / 9) / (2731 / 1536), 10);
    expect(crop.x).toBeCloseTo((1 - crop.width) / 2, 10);
    expect(crop.y).toBe(0);
  });

  it("縦長画像では上下を中央で切り抜く", () => {
    expect(centeredCropForAspect(3000, 4000)).toEqual({
      x: 0,
      y: 0.2890625,
      width: 1,
      height: 0.421875,
    });
  });
});

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
  joinWithPrevious: false,
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

  it("連結パートの出演順は重複として扱わない", () => {
    expect([...duplicateOrders([
      { order: 1 },
      { order: 1, joinWithPrevious: true },
      { order: 2 },
    ])]).toEqual([]);
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

  it("分割動画は1バンドとして直結し，次のバンドだけクロスフェードする", () => {
    const first = clip("分割バンド", 10);
    const continuation = { ...clip("分割バンド", 8), id: "分割バンド-part2", joinWithPrevious: true };
    const next = clip("次のバンド", 20);
    const clips = [first, continuation, next];

    expect(bandCount(clips)).toBe(2);
    expect(clipGroups(clips).map((group) => group.length)).toEqual([2, 1]);
    expect(chapterRows(clips)).toEqual([
      { seconds: 0, text: "分割バンド" },
      { seconds: 17, text: "次のバンド" },
    ]);
    expect(projectDurationSeconds(clips)).toBeCloseTo(37.5, 1);
    expect(chapterWarnings(clips)).toEqual(["YouTubeのチャプター表示には3件以上の時刻が必要です。"]);
  });
});

describe("group ordering", () => {
  it("連結パートを分離せずバンド単位で並べ替える", () => {
    const first = clip("A", 10);
    const continuation = { ...clip("A", 8), id: "A-part2", joinWithPrevious: true };
    const second = { ...clip("B", 10), id: "B" };
    const third = { ...clip("C", 10), id: "C" };
    const moved = moveClipGroup([first, continuation, second, third], first.id, third.id);

    expect(moved.map((value) => value.id)).toEqual(["B", "C", "A", "A-part2"]);
    expect(moved.map((value) => value.order)).toEqual([1, 2, 3, 3]);
    expect(moved.map((value) => Boolean(value.joinWithPrevious))).toEqual([false, false, false, true]);
  });

  it("先頭の連結指定を正規化する", () => {
    const value = { ...clip("A", 10), joinWithPrevious: true };
    expect(renumberClipOrders([value])[0].joinWithPrevious).toBe(false);
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

describe("project compatibility", () => {
  it("v0.1.0～v0.4.0の保存データを読み込める", () => {
    const base = {
      schemaVersion: 1,
      eventName: "8月ライブ",
      clips: [],
      outputResolution: "1080p",
      transitionMs: 500,
      thumbnail: null,
    };
    expect(validateProject({ ...base, appVersion: "0.1.0" })).toBe(true);
    expect(validateProject({ ...base, appVersion: "0.2.0" })).toBe(true);
    expect(validateProject({ ...base, appVersion: "0.2.1" })).toBe(true);
    expect(validateProject({ ...base, appVersion: "0.3.0" })).toBe(true);
    expect(validateProject({ ...base, appVersion: "0.4.0" })).toBe(true);
  });
});


describe("source output settings", () => {
  it("自動設定を保存でき，不正なレートを拒否する", () => {
    const project = { schemaVersion: 1, appVersion: "0.4.0", eventName: "Live", clips: [], outputResolution: "source", outputFrameRate: "source", transitionMs: 500, thumbnail: null };
    expect(validateProject(JSON.parse(JSON.stringify(project)))).toBe(true);
    expect(validateProject({ ...project, outputFrameRate: "120" })).toBe(false);
  });
  it("自動解像度の見積もりを先頭素材の画素数に合わせる", () => {
    expect(estimateOutputBytes(60, "source", { width: 3840, height: 2160 })).toBe((60_000_000 + 384_000) * 60 / 8);
    expect(estimateOutputBytes(60, "1080p")).toBe((15_000_000 + 384_000) * 60 / 8);
  });
});
