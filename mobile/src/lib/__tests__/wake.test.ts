import { extractCommand, normalize } from "../wake";

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
