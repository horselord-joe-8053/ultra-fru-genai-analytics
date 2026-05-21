/**
 * Error handling utilities for backend errors
 * Provides consistent error logging and UI display
 */

/**
 * Truncates error message to first N words
 * @param error - Error object, string, or any value
 * @param maxWords - Maximum number of words (default: 15)
 * @returns Truncated error message
 */
export function truncateError(error: unknown, maxWords: number = 15): string {
  let errorMessage = "";
  
  if (error instanceof Error) {
    errorMessage = error.message || error.toString();
  } else if (typeof error === "string") {
    errorMessage = error;
  } else if (error && typeof error === "object") {
    // Try to extract message from error object
    const errObj = error as any;
    errorMessage = errObj.message || errObj.error || JSON.stringify(error);
  } else {
    errorMessage = String(error);
  }
  
  const words = errorMessage.trim().split(/\s+/);
  if (words.length <= maxWords) {
    return errorMessage;
  }
  
  return words.slice(0, maxWords).join(" ") + "...";
}

/**
 * Handles backend errors with proper logging and UI updates
 * @param error - The error to handle
 * @param context - Context where error occurred (for logging)
 * @returns Object with truncated error for UI and full error for console
 */
export function handleBackendError(
  error: unknown,
  context: string = "Unknown"
): { truncated: string; full: string } {
  // Get full error message
  let fullErrorMessage = "";
  
  if (error instanceof Error) {
    fullErrorMessage = `${error.name}: ${error.message}`;
    if (error.stack) {
      fullErrorMessage += `\n${error.stack}`;
    }
  } else if (typeof error === "string") {
    fullErrorMessage = error;
  } else if (error && typeof error === "object") {
    try {
      fullErrorMessage = JSON.stringify(error, null, 2);
    } catch {
      fullErrorMessage = String(error);
    }
  } else {
    fullErrorMessage = String(error);
  }
  
  // Log full error to console
  console.error(`[${context}] Backend Error:`, error);
  console.error(`[${context}] Full Error Details:`, fullErrorMessage);
  
  // Return truncated version for UI
  return {
    truncated: truncateError(error, 15),
    full: fullErrorMessage,
  };
}

