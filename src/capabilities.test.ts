import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

interface CapabilityFile {
  permissions: string[];
}

describe("Tauri window permissions", () => {
  it("保存確認後にウィンドウを破棄して終了できる", () => {
    const capability = JSON.parse(
      readFileSync(new URL("../src-tauri/capabilities/default.json", import.meta.url), "utf8"),
    ) as CapabilityFile;

    expect(capability.permissions).toContain("core:window:allow-destroy");
  });
});
