import React, { useEffect, useRef } from "react";

export interface ExecutionState {
  question: string | null;
  method: string | null;
  toolCalls: Array<{
    iteration: number;
    tool: string;
    input: any;
    output: any;
    execution_time_ms: number;
  }>;
  iterations: number | null;
  execution_time_ms: number | null;
  token_usage: {
    input_tokens: number;
    output_tokens: number;
    total_tokens: number;
  } | null;
  answer: string | null;
  isStreaming: boolean;
  error: string | null;
}

interface ExecutionPanelProps {
  state: ExecutionState;
}

const ExecutionPanel: React.FC<ExecutionPanelProps> = ({ state }) => {
  const scrollRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new content arrives
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [state.toolCalls, state.iterations, state.execution_time_ms, state.token_usage]);

  const formatValue = (value: any): string => {
    if (value === null || value === undefined) {
      return "null";
    }
    if (typeof value === "object") {
      return JSON.stringify(value, null, 2);
    }
    return String(value);
  };

  const getInputField = (input: any, tool: string): string => {
    // Try to find the most relevant input field based on tool type
    if (tool === "generate_sql" || tool === "sql_generator") {
      return input?.query || input?.question || formatValue(input);
    }
    if (tool === "execute_sql") {
      return input?.sql_query || input?.sql || formatValue(input);
    }
    if (tool === "semantic_search") {
      const parts: string[] = [];
      if (input?.feedback_rating_max !== undefined) {
        parts.push(`feedback_rating_max: ${input.feedback_rating_max}`);
      }
      if (input?.feedback_rating_min !== undefined) {
        parts.push(`feedback_rating_min: ${input.feedback_rating_min}`);
      }
      if (input?.feedback_sentiment_category) {
        parts.push(`feedback_sentiment_category: ${input.feedback_sentiment_category}`);
      }
      return parts.length > 0 ? parts.join(", ") : formatValue(input);
    }
    return formatValue(input);
  };

  return (
    <div className="h-full flex flex-col bg-gray-50">
      <div className="p-3 border-b bg-white">
        <h2 className="text-sm font-semibold text-gray-700">Execution Log</h2>
        {state.isStreaming && (
          <div className="text-xs text-blue-600 mt-1">● Streaming...</div>
        )}
        {state.error && (
          <div className="text-xs text-red-600 mt-1">Error: {state.error}</div>
        )}
      </div>
      
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto p-3 font-mono text-xs"
        style={{ fontSize: "11px", lineHeight: "1.5" }}
      >
        {/* Part 1: Query Info */}
        {(state.question || state.method) && (
          <div className="mb-4">
            <div className="text-gray-600 font-semibold mb-2">=== Part 1 ===</div>
            {state.question && (
              <div className="text-gray-800 mb-1">
                <span className="text-gray-500">question:</span> {state.question}
              </div>
            )}
            {state.method && (
              <div className="text-gray-800 mb-1">
                <span className="text-gray-500">method:</span> {state.method}
              </div>
            )}
          </div>
        )}

        {/* Part 2: Tool Calls */}
        {state.toolCalls.length > 0 && (
          <div className="mb-4">
            <div className="text-gray-600 font-semibold mb-2">=== Part 2 ===</div>
            {state.toolCalls.map((toolCall, index) => (
              <div key={index} className="mb-3 border-l-2 border-gray-300 pl-2">
                <div className="text-gray-500 mb-1">----------------------------------------</div>
                <div className="text-gray-800 mb-1">
                  <span className="text-gray-500">iteration:</span> {toolCall.iteration}
                </div>
                <div className="text-gray-800 mb-1">
                  <span className="text-gray-500">tool:</span> {toolCall.tool}
                </div>
                <div className="text-gray-800 mb-1">
                  <span className="text-gray-500">input.{toolCall.tool === "generate_sql" ? "query" : toolCall.tool === "execute_sql" ? "sql_query" : "params"}:</span>{" "}
                  {getInputField(toolCall.input, toolCall.tool)}
                </div>
                {toolCall.output?.summary && (
                  <div className="text-gray-800 mb-1">
                    <span className="text-gray-500">output.summary:</span> {toolCall.output.summary}
                  </div>
                )}
                {toolCall.output?.error && (
                  <div className="text-red-600 mb-1">
                    <span className="text-gray-500">output.error:</span> {toolCall.output.error}
                  </div>
                )}
                <div className="text-gray-800 mb-1">
                  <span className="text-gray-500">execution_time_ms:</span> {toolCall.execution_time_ms.toFixed(2)}
                </div>
                <div className="text-gray-500 mt-1">----------------------------------------</div>
              </div>
            ))}
          </div>
        )}

        {/* Part 3: Final Stats */}
        {(state.iterations !== null || state.execution_time_ms !== null) && (
          <div className="mb-4">
            <div className="text-gray-600 font-semibold mb-2">=== Part 3 ===</div>
            {state.iterations !== null && (
              <div className="text-gray-800 mb-1">
                <span className="text-gray-500">iterations:</span> {state.iterations}
              </div>
            )}
            {state.execution_time_ms !== null && (
              <div className="text-gray-800 mb-1">
                <span className="text-gray-500">execution_time_ms:</span> {state.execution_time_ms.toFixed(2)}
              </div>
            )}
          </div>
        )}

        {/* Part 4: Token Usage */}
        {state.token_usage && (
          <div className="mb-4">
            <div className="text-gray-600 font-semibold mb-2">=== Part 4 ===</div>
            <div className="text-gray-800 mb-1">
              <span className="text-gray-500">token_usage.input_tokens:</span> {state.token_usage.input_tokens}
            </div>
            <div className="text-gray-800 mb-1">
              <span className="text-gray-500">token_usage.output_tokens:</span> {state.token_usage.output_tokens}
            </div>
            <div className="text-gray-800 mb-1">
              <span className="text-gray-500">token_usage.total_tokens:</span> {state.token_usage.total_tokens}
            </div>
          </div>
        )}

        {/* Empty state */}
        {!state.question && state.toolCalls.length === 0 && !state.isStreaming && (
          <div className="text-gray-400 text-center mt-8">
            No execution log yet. Send a query to see the execution process.
          </div>
        )}
      </div>
    </div>
  );
};

export default ExecutionPanel;

