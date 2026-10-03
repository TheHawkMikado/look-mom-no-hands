import type { MetadataRoute } from "next";

/** Keep the private pages out of search. The beta page is also marked
 *  noindex in its own metadata; this stops crawlers fetching it at all. */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: "*", allow: "/", disallow: ["/beta", "/admin", "/account", "/status", "/team", "/api/"] }],
  };
}
