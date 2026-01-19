/**
 * Build version utility
 * Generates version string in format V_YYMMDD-HHMMSS_PROVIDER_CONTAINER_ENV
 * Example: V_260118-120000_aws_eks_dev
 */

// Declare build context constants injected by Vite
declare const BUILD_TIME: number;
declare const BUILD_PROVIDER: string;
declare const BUILD_CONTAINER_TYPE: string;
declare const BUILD_ENVIRONMENT: string;

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
 * Uses BUILD_TIME and build context (provider, container type, environment) from Vite at build time
 * Falls back to fixed values if not available (ensures version stays static)
 */
export function getBuildVersion(): string {
  // BUILD_TIME is injected by Vite at build time
  // Use a fixed fallback timestamp if not available (ensures version stays static until new build)
  const buildTime = typeof BUILD_TIME !== "undefined" ? BUILD_TIME : 1700000000000; // Fixed fallback: 2023-11-14 12:26:40 UTC
  const buildDate = new Date(buildTime);
  const timestamp = formatBuildTime(buildDate);
  
  // Build context (provider, container type, environment) - injected by Vite from env vars
  const provider = typeof BUILD_PROVIDER !== "undefined" ? BUILD_PROVIDER : "local";
  const containerType = typeof BUILD_CONTAINER_TYPE !== "undefined" ? BUILD_CONTAINER_TYPE : "none";
  const environment = typeof BUILD_ENVIRONMENT !== "undefined" ? BUILD_ENVIRONMENT : "dev";
  
  return `V_${timestamp}_${provider}_${containerType}_${environment}`;
}

