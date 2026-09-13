import { parseNotificationData } from "../notificationData";

describe("parseNotificationData", () => {
  it("finds an approval id", () => {
    expect(parseNotificationData({ approvalId: "ap_1" })).toEqual({
      kind: "approval",
      approvalId: "ap_1",
    });
  });

  it("finds a prompt id, including numeric ones", () => {
    expect(parseNotificationData({ promptId: 42 })).toEqual({
      kind: "prompt",
      promptId: "42",
    });
  });

  it("prefers the approval when both are present", () => {
    expect(parseNotificationData({ approvalId: "a", promptId: "p" })?.kind).toBe("approval");
  });

  it("returns null for anything else", () => {
    expect(parseNotificationData(null)).toBeNull();
    expect(parseNotificationData("approvalId")).toBeNull();
    expect(parseNotificationData({ approvalId: "  " })).toBeNull();
    expect(parseNotificationData({ other: 1 })).toBeNull();
  });
});
