import React, { useState } from "react";
import Chat from "./components/Chat";
import BatchAnalyticsPanel from "./components/BatchAnalyticsPanel";

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

  // Use relative URL - CloudFront will proxy /query requests to ALB
  // In development, Vite proxy handles /query -> localhost:5000
  // In production, CloudFront cache behavior proxies /query -> ALB
  async function sendQuery(text: string) {
    if (!text.trim() || loading) return;
    setMessages((prev) => [...prev, { role: "user", text }]);
    setLoading(true);

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
