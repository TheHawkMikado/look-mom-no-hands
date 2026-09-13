import type { Task } from "../api";
import { countNeedingOwner, groupOfStatus, groupTasks } from "../taskGroups";

const task = (id: string, status: string): Task =>
  ({ id, status, title: id } as unknown as Task);

describe("groupTasks", () => {
  it("buckets by status in display order, omitting empty buckets", () => {
    const groups = groupTasks([
      task("a", "done"),
      task("b", "in_progress"),
      task("c", "needs_decision"),
      task("d", "awaiting_approval"),
      task("e", "failed"),
      task("f", "triaged"),
    ]);
    expect(groups.map((g) => g.key)).toEqual([
      "your_call",
      "needs_approval",
      "working",
      "done",
    ]);
    expect(groups[2].tasks.map((t) => t.id)).toEqual(["b", "f"]);
    expect(groups[3].tasks.map((t) => t.id)).toEqual(["a", "e"]);
    expect(groupTasks([task("x", "done")]).map((g) => g.key)).toEqual(["done"]);
  });

  it("lands unknown statuses in working", () => {
    expect(groupOfStatus("brand_new_status")).toBe("working");
  });
});

describe("countNeedingOwner", () => {
  it("counts only decisions and approvals", () => {
    expect(
      countNeedingOwner([
        task("a", "needs_decision"),
        task("b", "awaiting_approval"),
        task("c", "in_progress"),
        task("d", "done"),
      ]),
    ).toBe(2);
  });
});
