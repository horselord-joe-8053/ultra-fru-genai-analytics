import React, { useState, useEffect, useRef } from "react";
import Chat from "./components/Chat";
import BatchAnalyticsPanel from "./components/BatchAnalyticsPanel";
import ExecutionPanel, { ExecutionState } from "./components/ExecutionPanel";
import { handleBackendError } from "./utils/errorHandler";

export interface Message {
  role: "user" | "assistant";
  text: string;
}

export interface QueryResponse {
  question: string;
  mode: string;
  answer: string;
}

const App: React.FC = () => {
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [executionState, setExecutionState] = useState<ExecutionState>({
    question: null,
    method: null,
    toolCalls: [],
    iterations: null,
    execution_time_ms: null,
    token_usage: null,
    answer: null,
    isStreaming: false,
    error: null,
  });
  const eventSourceRef = useRef<EventSource | null>(null);

  // Calculate initial panel widths from percentage env vars
  const getInitialPanelWidths = () => {
    const viewportWidth = window.innerWidth;
    
    const execLogPercent = parseFloat(
      import.meta.env.VITE_FRONTEND_EXEC_LOG_PANEL_WIDTH_PERCENT || "0.3"
    );
    const batchAnalyticPercent = parseFloat(
      import.meta.env.VITE_FRONTEND_BATCH_ANALYTIC_PANEL_WIDTH_PERCENT || "0.2"
    );
    
    return {
      executionLog: Math.floor(viewportWidth * execLogPercent),
      batchAnalytics: Math.floor(viewportWidth * batchAnalyticPercent),
    };
  };

  // Panel visibility and width state
  const [panelVisibility, setPanelVisibility] = useState(() => {
    const saved = localStorage.getItem("panelVisibility");
    return saved ? JSON.parse(saved) : { executionLog: true, batchAnalytics: true };
  });
  const [panelWidths, setPanelWidths] = useState(() => getInitialPanelWidths());
  const [isResizing, setIsResizing] = useState<string | null>(null);
  const [resizeStartX, setResizeStartX] = useState(0);
  const [resizeStartWidth, setResizeStartWidth] = useState(0);
  const resizeRef = useRef<{ panel: string; startX: number; startWidth: number } | null>(null);

  // Save panel visibility to localStorage
  useEffect(() => {
    localStorage.setItem("panelVisibility", JSON.stringify(panelVisibility));
  }, [panelVisibility]);

  // Cleanup EventSource on unmount
  useEffect(() => {
    return () => {
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
        eventSourceRef.current = null;
      }
    };
  }, []);

  // Handle panel visibility toggle
  const toggleExecutionLog = () => {
    setPanelVisibility((prev: { executionLog: boolean; batchAnalytics: boolean }) => ({ ...prev, executionLog: !prev.executionLog }));
  };

  const toggleBatchAnalytics = () => {
    setPanelVisibility((prev: { executionLog: boolean; batchAnalytics: boolean }) => ({ ...prev, batchAnalytics: !prev.batchAnalytics }));
  };

  // Resize handlers
  const handleResizeStart = (panel: string, e: React.MouseEvent) => {
    e.preventDefault();
    setIsResizing(panel);
    setResizeStartX(e.clientX);
    setResizeStartWidth(panelWidths[panel as keyof typeof panelWidths]);
    resizeRef.current = {
      panel,
      startX: e.clientX,
      startWidth: panelWidths[panel as keyof typeof panelWidths],
    };
  };

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!isResizing || !resizeRef.current) return;

      const deltaX = e.clientX - resizeRef.current.startX;
      // The resize handles are positioned BEFORE the panels in the flex layout
      // When dragging RIGHT (positive deltaX), the boundary should move RIGHT
      // This means the panel AFTER the handle should get WIDER
      // Since the handle is BEFORE the panel, dragging right should increase the panel width
      // However, the user reports it moves opposite, so we invert the sign
      const newWidth = resizeRef.current.startWidth - deltaX;
      const minWidth = 200;

      if (newWidth >= minWidth) {
        setPanelWidths((prev: { executionLog: number; batchAnalytics: number }) => ({
          ...prev,
          [resizeRef.current!.panel]: newWidth,
        }));
      }
    };

    const handleMouseUp = () => {
      setIsResizing(null);
      resizeRef.current = null;
    };

    if (isResizing) {
      document.addEventListener("mousemove", handleMouseMove);
      document.addEventListener("mouseup", handleMouseUp);
      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
    }

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
  }, [isResizing]);

  // Sync Chat panel with Execution Log - update when answer arrives
  useEffect(() => {
    if (executionState.answer && executionState.question) {
      // Find the last user message that matches this question
      const userMessages = messages.filter(m => m.role === "user");
      const lastUserMessage = userMessages[userMessages.length - 1];
      
      // Find the last assistant message
      const assistantMessages = messages.filter(m => m.role === "assistant");
      const lastAssistantMessage = assistantMessages[assistantMessages.length - 1];
      
      // Only add answer if:
      // 1. Last user message matches the question
      // 2. We haven't added this answer yet
      if (lastUserMessage?.text === executionState.question &&
          lastAssistantMessage?.text !== executionState.answer) {
        setMessages((prev) => [
          ...prev,
          { 
            role: "assistant", 
            text: executionState.answer || "[No answer returned]" 
          },
        ]);
      }
    }
  }, [executionState.answer, executionState.question, messages]);

  // Sync loading state with streaming status
  useEffect(() => {
    setLoading(executionState.isStreaming);
  }, [executionState.isStreaming]);

  // Use relative URL - CloudFront will proxy /query requests to ALB
  // In development, Vite proxy handles /query -> localhost:5000
  // In production, CloudFront cache behavior proxies /query -> ALB
  async function sendQuery(text: string) {
    if (!text.trim() || loading) return;
    setMessages((prev) => [...prev, { role: "user", text }]);
    setLoading(true);

    // Reset execution state
    setExecutionState({
      question: null,
      method: null,
      toolCalls: [],
      iterations: null,
      execution_time_ms: null,
      token_usage: null,
      answer: null,
      isStreaming: true,
      error: null,
    });

    // Close any existing EventSource
    if (eventSourceRef.current) {
      eventSourceRef.current.close();
      eventSourceRef.current = null;
    }

    // Start streaming execution log
    const eventSource = new EventSource(
      `/query/stream?query=${encodeURIComponent(text)}`
    );
    eventSourceRef.current = eventSource;

    // Handle SSE events
    eventSource.addEventListener("question", (event) => {
      const data = JSON.parse(event.data);
      setExecutionState((prev) => ({
        ...prev,
        question: data.question,
      }));
    });

    eventSource.addEventListener("method", (event) => {
      const data = JSON.parse(event.data);
      setExecutionState((prev) => ({
        ...prev,
        method: data.method,
      }));
    });

    eventSource.addEventListener("tool_call_complete", (event) => {
      const data = JSON.parse(event.data);
      setExecutionState((prev) => ({
        ...prev,
        toolCalls: [
          ...prev.toolCalls,
          {
            iteration: data.iteration !== null && data.iteration !== undefined ? data.iteration : null,
            tool: data.tool,
            input: data.input,
            output: data.output,
            execution_time_ms: data.execution_time_ms,
          },
        ],
      }));
    });

    eventSource.addEventListener("complete", (event) => {
      const data = JSON.parse(event.data);
      setExecutionState((prev) => ({
        ...prev,
        iterations: data.iterations,
        execution_time_ms: data.execution_time_ms,
        token_usage: data.token_usage,
        answer: data.answer || null,
        isStreaming: false,
      }));
      eventSource.close();
      eventSourceRef.current = null;
    });

    // Handle error events from server
    eventSource.addEventListener("error", (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data);
        const errorMessage = data.message || "Unknown error";
        
        // Handle error with proper logging and truncation
        const { truncated } = handleBackendError(errorMessage, "Server Error Event");
        
        setExecutionState((prev) => ({
          ...prev,
          error: truncated,
          isStreaming: false,
        }));
        
        // Also update Chat panel with user-friendly error
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            text: `Sorry, an error occurred: ${errorMessage}`,
          },
        ]);
      } catch (e) {
        // JSON parse failed - handle the parsing error
        const { truncated } = handleBackendError(e, "Server Error Event (JSON Parse Failed)");
        
        setExecutionState((prev) => ({
          ...prev,
          error: truncated,
          isStreaming: false,
        }));
        
        // Update Chat panel with generic error
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            text: "Sorry, something went wrong while processing your query.",
          },
        ]);
      }
      setLoading(false);
      eventSource.close();
      eventSourceRef.current = null;
    });

    // Handle connection errors
    eventSource.onerror = (error) => {
      // Handle error with proper logging and truncation
      const { truncated } = handleBackendError(error, "EventSource Connection");
      
      // Only set error if we haven't received a complete event
      setExecutionState((prev) => {
        if (prev.isStreaming) {
          return {
            ...prev,
            error: truncated,
            isStreaming: false,
          };
        }
        return prev;
      });
      // Update Chat panel with user-friendly error
      setMessages((prev) => [
        ...prev,
        {
          role: "assistant",
          text: "Sorry, the connection was interrupted. Please try again.",
        },
      ]);
      
      setLoading(false);
      eventSource.close();
      eventSourceRef.current = null;
    };

    // ❌ REMOVED: Duplicate /query fetch call
    // Chat panel now gets answer from Execution Log's complete event
    // (handled in useEffect that watches executionState.answer)
  }

  return (
    <div className="flex h-full">
      {/* Chat Panel - Always visible, flexible width */}
      <div className="flex-1 border-r bg-white">
        <Chat messages={messages} onSend={sendQuery} loading={loading} />
      </div>

      {/* Execution Log Panel with Resize Handle */}
      {panelVisibility.executionLog && (
        <>
          {/* Resize Handle - Left side (between Chat and Execution Log) */}
          <div
            className="w-1 bg-gray-300 hover:bg-blue-500 cursor-col-resize transition-colors flex-shrink-0 relative group"
            onMouseDown={(e) => handleResizeStart("executionLog", e)}
            style={{ cursor: isResizing === "executionLog" ? "col-resize" : "col-resize" }}
          >
            <div className="absolute inset-y-0 left-0 right-0 group-hover:bg-blue-500 opacity-0 group-hover:opacity-100 transition-opacity" />
          </div>
          <div
            className="bg-gray-50 border-l border-r flex flex-col flex-shrink-0 transition-all duration-200 overflow-hidden"
            style={{ width: `${panelWidths.executionLog}px` }}
          >
            <ExecutionPanel
              state={executionState}
              onToggle={toggleExecutionLog}
              isVisible={panelVisibility.executionLog}
            />
          </div>
        </>
      )}

      {/* Batch Analytics Panel with Resize Handle */}
      {panelVisibility.batchAnalytics && (
        <>
          {/* Resize Handle - Between Execution Log and Batch Analytics (only if Execution Log is visible) */}
          {panelVisibility.executionLog && (
            <div
              className="w-1 bg-gray-300 hover:bg-blue-500 cursor-col-resize transition-colors flex-shrink-0 relative group"
              onMouseDown={(e) => handleResizeStart("batchAnalytics", e)}
              style={{ cursor: isResizing === "batchAnalytics" ? "col-resize" : "col-resize" }}
            >
              <div className="absolute inset-y-0 left-0 right-0 group-hover:bg-blue-500 opacity-0 group-hover:opacity-100 transition-opacity" />
            </div>
          )}
          <div
            className="bg-gray-50 flex flex-col border-l flex-shrink-0 transition-all duration-200 overflow-hidden"
            style={{ width: `${panelWidths.batchAnalytics}px` }}
          >
            <div className="flex-1 overflow-hidden">
              <BatchAnalyticsPanel
                onToggle={toggleBatchAnalytics}
                isVisible={panelVisibility.batchAnalytics}
              />
            </div>
          </div>
        </>
      )}

      {/* Show toggle buttons when panels are hidden */}
      {!panelVisibility.executionLog && (
        <div className="flex items-center border-l">
          <button
            onClick={toggleExecutionLog}
            className="px-3 py-4 bg-gray-50 hover:bg-gray-100 text-gray-500 hover:text-gray-700 transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1"
            title="Show Execution Log"
            aria-label="Show Execution Log"
          >
            <span className="text-sm font-medium">◀</span>
          </button>
        </div>
      )}
      {!panelVisibility.batchAnalytics && (
        <div className="flex items-center border-l">
          <button
            onClick={toggleBatchAnalytics}
            className="px-3 py-4 bg-gray-50 hover:bg-gray-100 text-gray-500 hover:text-gray-700 transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1"
            title="Show Batch Analytics"
            aria-label="Show Batch Analytics"
          >
            <span className="text-sm font-medium">◀</span>
          </button>
        </div>
      )}
    </div>
  );
};

export default App;
