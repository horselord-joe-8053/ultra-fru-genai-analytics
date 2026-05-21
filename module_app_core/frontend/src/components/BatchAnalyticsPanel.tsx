import React, { useState, useEffect } from "react";

interface BatchAnalyticsData {
  id: number;
  last_updated_at: string;
  sales_by_brand: Array<{
    brand: string;
    total_sales: number;
    total_revenue: number;
    avg_price: number;
  }>;
  store_performance: Array<{
    store_name: string;
    total_sales: number;
    total_revenue: number;
    negative_feedback_rate: number;
  }>;
  feedback_analysis: Array<{
    brand: string;
    feedback_sentiment_category: string;
    count: number;
  }>;
  top_models: Array<{
    brand: string;
    fridge_model: string;
    sales_count: number;
    total_revenue: number;
  }>;
  price_stats: {
    mean_price: number;
    min_price: number;
    max_price: number;
  };
  total_records: number;
  total_revenue: number;
}

interface BatchAnalyticsPanelProps {
  onToggle?: () => void;
  isVisible?: boolean;
}

const BatchAnalyticsPanel: React.FC<BatchAnalyticsPanelProps> = ({ onToggle, isVisible = true }) => {
  const [data, setData] = useState<BatchAnalyticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Use relative URL - CloudFront will proxy /analytics requests to ALB
  // In development, Vite proxy handles /analytics -> localhost:5000
  // In production, CloudFront cache behavior proxies /analytics -> ALB
  const fetchAnalytics = async () => {
    try {
      setLoading(true);
      setError(null);
      const resp = await fetch("/analytics");
      
      // Check content type to detect HTML responses (CloudFront routing issue)
      const contentType = resp.headers.get("content-type") || "";
      if (contentType.includes("text/html")) {
        // Received HTML instead of JSON - likely CloudFront routing issue
        const isProduction = window.location.hostname.includes("cloudfront.net");
        setError(
          isProduction
            ? "Backend API not reachable. CloudFront may not be routing /analytics to the backend. Check CloudFront cache behaviors configuration."
            : "Backend API not reachable. Check that the backend is running and Vite proxy is configured correctly."
        );
        setData(null);
        setLoading(false);
        return;
      }
      
      // Try to parse as JSON, but check for HTML content first
      const text = await resp.text();
      if (text.trim().startsWith("<!") || text.trim().startsWith("<html")) {
        // Received HTML content even though content-type might be wrong
        const isProduction = window.location.hostname.includes("cloudfront.net");
        setError(
          isProduction
            ? "Backend API not reachable. CloudFront may not be routing /analytics to the backend. Check CloudFront cache behaviors configuration."
            : "Backend API not reachable. Check that the backend is running and Vite proxy is configured correctly."
        );
        setData(null);
        setLoading(false);
        return;
      }
      
      const result = JSON.parse(text);
      
      // Check if response contains an error message (backend returns 200 with error field when no data)
      if (result.error && (resp.status === 200 || resp.status === 404)) {
        setError(result.error || "Analytics data not available yet. Waiting for first batch run...");
        setData(null);
        return;
      }
      
      if (!resp.ok) {
        if (resp.status === 404) {
          setError("Analytics data not available yet. Waiting for first batch run...");
          setData(null);
          return;
        }
        throw new Error(`HTTP ${resp.status}`);
      }
      
      setData(result);
    } catch (e: any) {
      console.error("Failed to fetch analytics:", e);
      // Check if error is due to HTML response
      if (e.message && (e.message.includes("Unexpected token '<'") || e.message.includes("<!doctype"))) {
        const isProduction = window.location.hostname.includes("cloudfront.net");
        setError(
          isProduction
            ? "Backend API not reachable. CloudFront may not be routing /analytics to the backend. Check CloudFront cache behaviors configuration."
            : "Backend API not reachable. Check that the backend is running and Vite proxy is configured correctly."
        );
      } else {
        setError(e.message || "Failed to load analytics");
      }
      setData(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchAnalytics();
    // Auto-refresh at configurable interval (default 60 seconds)
    const pollIntervalSeconds = parseInt(
      import.meta.env.VITE_FRONTEND_POLL_FREQUENCY_IN_SEC || "60",
      10
    );
    const pollIntervalMs = pollIntervalSeconds * 1000;
    const interval = setInterval(fetchAnalytics, pollIntervalMs);
    return () => clearInterval(interval);
  }, []);

  const formatCurrency = (value: number) => {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).format(value);
  };

  const formatRelativeTime = (isoString: string) => {
    const date = new Date(isoString);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffMins = Math.floor(diffMs / 60000);
    
    if (diffMins < 1) return "Just now";
    if (diffMins < 60) return `${diffMins} minute${diffMins > 1 ? "s" : ""} ago`;
    const diffHours = Math.floor(diffMins / 60);
    if (diffHours < 24) return `${diffHours} hour${diffHours > 1 ? "s" : ""} ago`;
    const diffDays = Math.floor(diffHours / 24);
    return `${diffDays} day${diffDays > 1 ? "s" : ""} ago`;
  };

  if (loading && !data) {
    return (
      <div className="h-full flex flex-col p-3">
        <h2 className="text-sm font-semibold mb-2">Batch Analytics</h2>
        <div className="text-xs text-gray-500">Loading...</div>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="h-full flex flex-col p-3">
        <h2 className="text-sm font-semibold mb-2">Batch Analytics</h2>
        <div className="text-xs text-red-600">{error}</div>
        <button
          onClick={fetchAnalytics}
          className="mt-2 text-xs text-blue-600 hover:underline"
        >
          Retry
        </button>
      </div>
    );
  }

  if (!data) {
    return null;
  }

  return (
    <div className="h-full flex flex-col p-3 space-y-3 text-sm overflow-auto">
      <div>
        <div className="flex items-center justify-between mb-1">
          <h2 className="text-sm font-semibold text-gray-800">
            Batch Analytics
          </h2>
          <div className="flex items-center gap-2">
            <button
              onClick={fetchAnalytics}
              className="text-xs text-blue-600 hover:underline"
              title="Refresh"
            >
              ↻
            </button>
            {onToggle && (
              <button
                onClick={onToggle}
                className="w-6 h-6 flex items-center justify-center rounded-md text-gray-400 hover:text-gray-600 hover:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1 transition-all duration-200"
                title={isVisible ? "Hide panel" : "Show panel"}
                aria-label={isVisible ? "Hide panel" : "Show panel"}
              >
                <span className="text-xs font-medium">{isVisible ? "×" : "+"}</span>
              </button>
            )}
          </div>
        </div>
        <p className="text-[0.6875rem] text-gray-500">
          Spark + Delta offline analytics
        </p>
        {data.last_updated_at && (
          <p className="text-xs text-gray-400 mt-1">
            Updated {formatRelativeTime(data.last_updated_at)}
          </p>
        )}
      </div>

      <div className="space-y-2">
        {/* Summary Stats */}
        <div className="bg-blue-50 p-2 rounded">
          <div className="text-[0.6875rem] font-semibold text-gray-700 mb-1">
            Summary
          </div>
          <div className="text-[0.6875rem] space-y-1">
            <div className="flex justify-between">
              <span>Total Records:</span>
              <span className="font-mono text-[0.6875rem]">
                {(data.total_records ?? 0).toLocaleString()}
              </span>
            </div>
            <div className="flex justify-between">
              <span>Total Revenue:</span>
              <span className="font-mono text-[0.6875rem]">
                {formatCurrency(data.total_revenue ?? 0)}
              </span>
            </div>
            <div className="flex justify-between">
              <span>Avg Price:</span>
              <span className="font-mono text-[0.6875rem]">
                {formatCurrency(data.price_stats?.mean_price || 0)}
              </span>
            </div>
          </div>
        </div>

        {/* Top Brands */}
        {data.sales_by_brand && data.sales_by_brand.length > 0 && (
          <div className="mt-8">
            <div className="text-[0.5625rem] font-semibold text-gray-700 mb-1">
              Top Brands by Sales
            </div>
            <div className="space-y-1 max-h-48 overflow-auto">
              {data.sales_by_brand.slice(0, 8).map((item, idx) => (
                <div
                  key={idx}
                  className="flex justify-between text-[0.45rem] bg-gray-50 p-1 rounded"
                >
                  <span className="truncate max-w-[50%]" title={item.brand}>
                    {item.brand}
                  </span>
                  <span className="font-mono">
                    {item.total_sales} ({formatCurrency(item.total_revenue)})
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Store Performance */}
        {data.store_performance && data.store_performance.length > 0 && (
          <div className="mt-8">
            <div className="text-[0.5625rem] font-semibold text-gray-700 mb-1">
              Store Performance
            </div>
            <div className="space-y-1 max-h-64 overflow-auto">
              {data.store_performance.slice(0, 8).map((item, idx) => (
                <div
                  key={idx}
                  className="text-[0.45rem] bg-gray-50 p-1 rounded"
                >
                  <div className="flex justify-between">
                    <span className="truncate max-w-[60%]" title={item.store_name}>
                      {item.store_name}
                    </span>
                    <span className="font-mono">
                      {formatCurrency(item.total_revenue)}
                    </span>
                  </div>
                  <div className="text-[0.45rem] text-gray-500 mt-0.5">
                    {item.total_sales} sales •{" "}
                    {item.negative_feedback_rate.toFixed(1)}% negative
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Top Models */}
        {data.top_models && data.top_models.length > 0 && (
          <div className="mt-8">
            <div className="text-[0.5625rem] font-semibold text-gray-700 mb-1">
              Top Models
            </div>
            <div className="space-y-1 max-h-48 overflow-auto">
              {data.top_models.slice(0, 8).map((item, idx) => (
                <div
                  key={idx}
                  className="flex justify-between text-[0.45rem] bg-gray-50 p-1 rounded"
                >
                  <span className="truncate max-w-[70%]" title={`${item.brand} ${item.fridge_model}`}>
                    {item.brand} {item.fridge_model}
                  </span>
                  <span className="font-mono">{item.sales_count}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default BatchAnalyticsPanel;

