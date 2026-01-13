/**
 * Build version utility
 * Generates version string in format V_YYMMDD-HHMMSS
 */

// Declare BUILD_TIME as a global constant injected by Vite
declare const BUILD_TIME: number;

/**
 * Formats a date to YYMMDD-HHMMSS format
 */
function formatBuildTime(date: Date): string {
  const year = date.getFullYear().toString().slice(-2);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const seconds = String(date.getSeconds()).padStart(2, "0");
  
  return `${year}${month}${day}-${hours}${minutes}${seconds}`;
}

/**
 * Gets the build version
 * Uses BUILD_TIME from Vite at build time
 * Falls back to a fixed timestamp if BUILD_TIME is not available (ensures version stays static)
 */
export function getBuildVersion(): string {
  // BUILD_TIME is injected by Vite at build time
  // Use a fixed fallback timestamp if not available (ensures version stays static until new build)
  const buildTime = typeof BUILD_TIME !== "undefined" ? BUILD_TIME : 1700000000000; // Fixed fallback: 2023-11-14 12:26:40 UTC
  const buildDate = new Date(buildTime);
  return `V_${formatBuildTime(buildDate)}`;
}

