import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL(process.env.SITE_URL ?? "https://nohandsapp.com"),
  title: "Look Ma, No Hands — run your Mac by voice",
  description:
    "A voice-first Mac app that opens apps, drives websites, clicks, types and takes notes — hands-free. Speech stays on your device.",
  openGraph: {
    title: "Look Ma, No Hands",
    description: "Run your Mac entirely by voice. Speech recognised on-device.",
    url: "/",
    siteName: "Look Ma, No Hands",
    type: "website",
  },
  twitter: { card: "summary_large_image", title: "Look Ma, No Hands" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
