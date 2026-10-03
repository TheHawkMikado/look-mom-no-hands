import { takeSegment } from "../segments";

describe("takeSegment", () => {
  it("returns the whole transcript on first cut", () => {
    expect(takeSegment(0, "hey mama open safari")).toEqual({
      segment: "hey mama open safari",
      processed: 20,
    });
  });

  it("returns only what arrived since the last cut", () => {
    const first = takeSegment(0, "hey mama open safari");
    const next = takeSegment(first.processed, "hey mama open safari adios mama");
    expect(next.segment).toBe("adios mama");
  });

  it("returns empty when nothing new arrived", () => {
    const first = takeSegment(0, "hello");
    expect(takeSegment(first.processed, "hello").segment).toBe("");
  });

  it("starts over when the transcript shrank (engine restart)", () => {
    const first = takeSegment(0, "a long earlier transcript");
    const next = takeSegment(first.processed, "fresh words");
    expect(next.segment).toBe("fresh words");
    expect(next.processed).toBe("fresh words".length);
  });

  it("trims whitespace from the cut", () => {
    expect(takeSegment(5, "hello   there  ").segment).toBe("there");
  });
});
