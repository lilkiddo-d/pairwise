import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock (off unless NEXT_PUBLIC_GEOBLOCK_COUNTRIES is set, e.g. "US,CU,IR,KP,SY").
 * Uses the country header Vercel attaches at the edge. This is a front-end courtesy control only;
 * on-chain access control is the ComplianceRegistry hook (off by default).
 */
const BLOCKED = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES || "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function middleware(req: NextRequest) {
  if (BLOCKED.length === 0) return NextResponse.next();
  const { pathname } = req.nextUrl;
  if (pathname.startsWith("/blocked") || pathname.startsWith("/risk")) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") || "").toUpperCase();
  if (country && BLOCKED.includes(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|deployments/|favicon|.*\\.(?:svg|png|ico|json)$).*)"],
};
