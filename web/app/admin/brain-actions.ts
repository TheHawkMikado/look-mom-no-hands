"use server";

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/auth";
import { reviewCandidate } from "@/lib/brain";

/** Shared Brain review (SPEC.md §8.3). Approve publishes a new version of the
 *  SOP attributed to a source user hash; reject closes the candidate. Both
 *  check the admin session inside the action, like app/admin/actions.ts. */

export async function adminBrainApprove(formData: FormData) {
  await requireAdmin();
  await reviewCandidate(String(formData.get("id")), "approve");
  revalidatePath("/admin");
}

export async function adminBrainReject(formData: FormData) {
  await requireAdmin();
  await reviewCandidate(String(formData.get("id")), "reject");
  revalidatePath("/admin");
}
