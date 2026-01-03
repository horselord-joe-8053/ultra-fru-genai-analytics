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
    answer: null,
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
        setExecutionState((prev) => ({
          ...prev,
          error: data.message || "Unknown error",
          isStreaming: false,
        }));
        
        // Also update Chat panel with error
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            text: `Sorry, an error occurred: ${data.message || "Unknown error"}`,
          },
        ]);
      } catch (e) {
        setExecutionState((prev) => ({
          ...prev,
          error: "Error processing query",
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
      // Update Chat panel with error
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
