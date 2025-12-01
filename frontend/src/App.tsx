import React, { useState } from "react";
import Chat from "./components/Chat";
import StatsPanel from "./components/StatsPanel";
import BatchAnalyticsPanel from "./components/BatchAnalyticsPanel";

export interface Message {
  role: "user" | "assistant";
  text: string;
}

export interface QueryStats {
  total_matches: number;
  by_brand: Record<string, number>;
  by_store: Record<string, number>;
  by_rating: Record<string, number>;
}

export interface QueryResponse {
  question: string;
  mode: string;
  stats: QueryStats;
  sample_records: any[];
  answer: string;
}

const App: React.FC = () => {
  const [messages, setMessages] = useState<Message[]>([]);
  const [analytics, setAnalytics] = useState<QueryResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendQuery(text: string) {
    if (!text.trim() || loading) return;
    setError(null);
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
      setAnalytics(data);
    } catch (e: any) {
      console.error(e);
      setError(e.message || "Request failed");
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
        <div className="flex-1 border-b overflow-hidden">
          <BatchAnalyticsPanel />
        </div>
        {/* Query Stats Panel (pgvector) */}
        <div className="flex-1 overflow-hidden">
          <StatsPanel data={analytics} error={error} />
        </div>
      </div>
    </div>
  );
};

export default App;
