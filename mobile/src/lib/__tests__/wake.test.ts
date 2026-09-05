import { extractCommand, normalize, splitStopPhrase } from "../wake";

describe("normalize", () => {
  it("lowercases, strips punctuation, collapses whitespace", () => {
    expect(normalize("  Hey,   MAMA!  Open   Safari. ")).toBe(
      "hey mama open safari",
    );
  });

  it("handles empty and punctuation-only input", () => {
    expect(normalize("")).toBe("");
    expect(normalize("?!... ,,")).toBe("");
  });
});

describe("extractCommand", () => {
  it("returns the command after the wake phrase", () => {
    expect(extractCommand("Hey Mama, open Safari")).toBe("open safari");
  });

  it("matches the momma spelling", () => {
    expect(extractCommand("hey momma restart the build")).toBe(
      "restart the build",
    );
  });

  it("matches the 'a mama' mishearing at the start only", () => {
    expect(extractCommand("A mama send the weekly report")).toBe(
      "send the weekly report",
    );
    // Mid-sentence "a mama" is CONTENT, not a wake phrase — matching it there
    // truncated real commands ("…to a mama in my contacts" → "in my contacts").
    expect(extractCommand("hey mama send a message to a mama in my contacts")).toBe(
      "send a message to a mama in my contacts",
    );
    expect(extractCommand("tell a mama I said hi")).toBeNull();
  });

  it("ignores leading filler before the phrase", () => {
    expect(extractCommand("um so hey mama check my email")).toBe(
      "check my email",
    );
  });

  it("returns null without a wake phrase", () => {
    expect(extractCommand("open safari please")).toBeNull();
  });

  it("returns null when nothing follows the phrase", () => {
    expect(extractCommand("hey mama")).toBeNull();
    expect(extractCommand("Hey Mama!")).toBeNull();
  });

  it("requires word boundaries", () => {
    expect(extractCommand("heymama open safari")).toBeNull();
    expect(extractCommand("hey mamama open safari")).toBeNull();
  });

  it("uses the last occurrence when recognition stacks attempts", () => {
    expect(
      extractCommand("hey mama open safari hey mama close safari"),
    ).toBe("close safari");
  });

  it("is punctuation and case insensitive around the phrase", () => {
    expect(extractCommand("HEY, MAMA: lock my screen")).toBe("lock my screen");
  });
});

describe("splitStopPhrase", () => {
  it("recognises a bare stop phrase", () => {
    expect(splitStopPhrase("Adios Mama")).toBe("");
    expect(splitStopPhrase("adios momma!")).toBe("");
  });

  it("returns the text spoken before the phrase", () => {
    expect(splitStopPhrase("send the report by five adios mama")).toBe(
      "send the report by five",
    );
  });

  it("tolerates a couple of trailing recognizer words", () => {
    expect(splitStopPhrase("that's all adios mama thank you")).toBe(
      "that s all",
    );
    // Too far from the end: the phrase is content, not a command to stop.
    expect(
      splitStopPhrase("adios mama is what I always say when I leave the room"),
    ).toBeNull();
  });

  it("matches the split 'ma ma' and accented mishearings", () => {
    expect(splitStopPhrase("adios ma ma")).toBe("");
    expect(splitStopPhrase("adiós mama")).toBe("");
  });

  it("returns null without a stop phrase", () => {
    expect(splitStopPhrase("open safari please")).toBeNull();
    expect(splitStopPhrase("")).toBeNull();
  });

  it("requires whole words", () => {
    expect(splitStopPhrase("radios mama")).toBeNull();
  });
});
