"use server";

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/auth";
import { setBetaEnabled } from "@/lib/db-beta";

export async function adminToggleBeta(formData: FormData) {
  await requireAdmin();
  await setBetaEnabled(formData.get("on") === "1");
  revalidatePath("/admin");
  revalidatePath("/beta");
}
