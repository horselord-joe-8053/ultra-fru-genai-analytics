import React, { useState, useRef, useEffect } from "react";
import type { Message } from "../App";
import { getBuildVersion } from "../utils/version";
import { getBackendVersion } from "../utils/backendVersion";

interface ChatProps {
  messages: Message[];
  onSend: (text: string) => void;
  loading: boolean;
}

const Chat: React.FC<ChatProps> = ({ messages, onSend, loading }) => {
  const [input, setInput] = useState("");
  const [backendVersion, setBackendVersion] = useState<string>("loading...");
  const bottomRef = useRef<HTMLDivElement | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!input.trim()) return;
    onSend(input.trim());
    setInput("");
  }

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, loading]);

  useEffect(() => {
    // Fetch backend version on component mount
    // Force refresh on mount to ensure we get the latest version after deployments
    getBackendVersion(true).then(setBackendVersion).catch(() => {
      // If force refresh fails, try with cache
      getBackendVersion(false).then(setBackendVersion);
    });
  }, []);

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-4 py-3 border-b bg-gray-50">
        <div>
          <h1 className="text-lg font-semibold">FRU Analytics Assistant</h1>
          <div className="text-[10px] text-gray-400 font-mono leading-tight space-y-0.5">
            <p>Frontend: {getBuildVersion()}</p>
            <p>Backend: {backendVersion}</p>
          </div>
          <p className="text-xs text-gray-500">
            Ask about sales, brands, stores, and customer feedback.
          </p>
        </div>
      </div>

      <div className="flex-1 overflow-auto px-4 py-3 space-y-3">
        {messages.length === 0 && (
          <div className="text-sm text-gray-500 mt-4">
            Try:{" "}
            <span className="italic">
              "What is the overall average customer rating?"
            </span>
          </div>
        )}
        {messages.map((m, i) => (
          <div
            key={i}
            className={`flex ${
              m.role === "user" ? "justify-end" : "justify-start"
            }`}
          >
            <div
              className={`px-3 py-2 rounded-lg max-w-[70%] text-sm whitespace-pre-wrap ${
                m.role === "user"
                  ? "bg-blue-600 text-white"
                  : "bg-gray-200 text-gray-900"
              }`}
            >
              {m.text}
            </div>
          </div>
        ))}
        {loading && (
          <div className="text-xs text-gray-400">Thinking…</div>
        )}
        <div ref={bottomRef} />
      </div>

      <form
        onSubmit={handleSubmit}
        className="flex items-center gap-2 p-3 border-t bg-gray-50"
      >
        <input
          className="flex-1 border rounded px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
          placeholder="Ask a question about FRU sales and feedback…"
          value={input}
          onChange={(e) => setInput(e.target.value)}
        />
        <button
          type="submit"
          disabled={loading}
          className="px-4 py-2 text-sm rounded bg-blue-600 text-white disabled:opacity-60"
        >
          Send
        </button>
      </form>
    </div>
  );
};

export default Chat;
