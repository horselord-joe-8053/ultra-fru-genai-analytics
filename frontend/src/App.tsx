import React, { useState, useEffect, useRef } from "react";
import Chat from "./components/Chat";
import BatchAnalyticsPanel from "./components/BatchAnalyticsPanel";
import ExecutionPanel, { ExecutionState } from "./components/ExecutionPanel";

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
    isStreaming: false,
    error: null,
  });
  const eventSourceRef = useRef<EventSource | null>(null);

  // Cleanup EventSource on unmount
  useEffect(() => {
    return () => {
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
        eventSourceRef.current = null;
      }
    };
  }, []);

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
            iteration: data.iteration,
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
        isStreaming: false,
      }));
      eventSource.close();
      eventSourceRef.current = null;
    });

    // Handle error events from server
    eventSource.addEventListener("error", (event: MessageEvent) => {
      try {
        const data = JSON.parse(event.data);
        setExecutionState((prev) => ({
          ...prev,
          error: data.message || "Unknown error",
          isStreaming: false,
        }));
      } catch (e) {
        setExecutionState((prev) => ({
          ...prev,
          error: "Error processing query",
          isStreaming: false,
        }));
      }
      eventSource.close();
      eventSourceRef.current = null;
    });

    // Handle connection errors
    eventSource.onerror = (error) => {
      console.error("EventSource connection error:", error);
      // Only set error if we haven't received a complete event
      setExecutionState((prev) => {
        if (prev.isStreaming) {
          return {
            ...prev,
            error: "Connection error - streaming interrupted",
            isStreaming: false,
          };
        }
        return prev;
      });
      eventSource.close();
      eventSourceRef.current = null;
    };

    // Also make regular query request for the answer
    try {
      const resp = await fetch("/query", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: text }),
      });

      if (!resp.ok) {
        const errText = await resp.text();
        throw new Error(errText || `HTTP ${resp.status}`);
      }

      const data: QueryResponse = await resp.json();
      setMessages((prev) => [
        ...prev,
        { role: "assistant", text: data.answer || "[No answer returned]" },
      ]);
    } catch (e: any) {
      console.error(e);
      setMessages((prev) => [
        ...prev,
        {
          role: "assistant",
          text: "Sorry, something went wrong while answering that question.",
        },
      ]);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex h-full">
      <div className="flex-1 border-r bg-white">
        <Chat messages={messages} onSend={sendQuery} loading={loading} />
      </div>
      <div className="w-[400px] bg-gray-50 border-l border-r flex flex-col">
        {/* Execution Panel (Real-time execution log) */}
        <ExecutionPanel state={executionState} />
      </div>
      <div className="w-[380px] bg-gray-50 flex flex-col border-l">
        {/* Batch Analytics Panel (Spark + Delta) */}
        <div className="flex-1 overflow-hidden">
          <BatchAnalyticsPanel />
        </div>
      </div>
    </div>
  );
};

export default App;
