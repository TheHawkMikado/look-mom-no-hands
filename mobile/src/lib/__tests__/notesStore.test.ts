import { deriveTitle, parseNotes, sortNotes } from "../notesStore";

describe("deriveTitle", () => {
  it("uses the first words", () => {
    expect(deriveTitle("meeting with the roofing crew tomorrow at nine")).toBe(
      "meeting with the roofing crew tomorrow…",
    );
  });

  it("keeps short notes whole, no ellipsis", () => {
    expect(deriveTitle("buy milk")).toBe("buy milk");
  });

  it("falls back for empty text", () => {
    expect(deriveTitle("   ")).toBe("Untitled note");
  });
});

describe("sortNotes", () => {
  it("orders newest first", () => {
    const notes = [
      { id: "a", title: "", text: "", createdAt: "2026-10-01T00:00:00Z", updatedAt: "", sentToMac: false },
      { id: "b", title: "", text: "", createdAt: "2026-10-03T00:00:00Z", updatedAt: "", sentToMac: false },
    ];
    expect(sortNotes(notes).map((n) => n.id)).toEqual(["b", "a"]);
  });
});

describe("parseNotes", () => {
  it("round-trips well-formed notes", () => {
    const notes = [
      { id: "a", title: "t", text: "x", createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z", sentToMac: true },
    ];
    expect(parseNotes(JSON.stringify(notes))).toEqual(notes);
  });

  it("drops malformed entries but keeps the rest", () => {
    const raw = JSON.stringify([
      { id: "good", text: "x", createdAt: "2026-10-01T00:00:00Z", title: "", updatedAt: "", sentToMac: false },
      { nope: true },
      "garbage",
    ]);
    expect(parseNotes(raw).map((n) => n.id)).toEqual(["good"]);
  });

  it("survives corrupt JSON and wrong shapes", () => {
    expect(parseNotes("{not json")).toEqual([]);
    expect(parseNotes('{"a":1}')).toEqual([]);
  });
});
