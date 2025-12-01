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
    feedback_rating: string;
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

const BatchAnalyticsPanel: React.FC = () => {
  const [data, setData] = useState<BatchAnalyticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchAnalytics = async () => {
    try {
      setLoading(true);
      setError(null);
      const resp = await fetch("/analytics");
      if (!resp.ok) {
        if (resp.status === 404) {
          setError("Analytics data not available yet. Waiting for first batch run...");
          setData(null);
          return;
        }
        throw new Error(`HTTP ${resp.status}`);
      }
      const result = await resp.json();
      setData(result);
    } catch (e: any) {
      console.error("Failed to fetch analytics:", e);
      setError(e.message || "Failed to load analytics");
      setData(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchAnalytics();
    // Auto-refresh every 60 seconds
    const interval = setInterval(fetchAnalytics, 60000);
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
          <button
            onClick={fetchAnalytics}
            className="text-xs text-blue-600 hover:underline"
            title="Refresh"
          >
            ↻
          </button>
        </div>
        <p className="text-xs text-gray-500">
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
          <div className="text-xs font-semibold text-gray-700 mb-1">
            Summary
          </div>
          <div className="text-xs space-y-1">
            <div className="flex justify-between">
              <span>Total Records:</span>
              <span className="font-mono">{data.total_records.toLocaleString()}</span>
            </div>
            <div className="flex justify-between">
              <span>Total Revenue:</span>
              <span className="font-mono">{formatCurrency(data.total_revenue)}</span>
            </div>
            <div className="flex justify-between">
              <span>Avg Price:</span>
              <span className="font-mono">
                {formatCurrency(data.price_stats?.mean_price || 0)}
              </span>
            </div>
          </div>
        </div>

        {/* Top Brands */}
        {data.sales_by_brand && data.sales_by_brand.length > 0 && (
          <div>
            <div className="text-xs font-semibold text-gray-700 mb-1">
              Top Brands by Sales
            </div>
            <div className="space-y-1 max-h-32 overflow-auto">
              {data.sales_by_brand.slice(0, 5).map((item, idx) => (
                <div
                  key={idx}
                  className="flex justify-between text-xs bg-gray-50 p-1 rounded"
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
          <div>
            <div className="text-xs font-semibold text-gray-700 mb-1">
              Store Performance
            </div>
            <div className="space-y-1 max-h-32 overflow-auto">
              {data.store_performance.slice(0, 3).map((item, idx) => (
                <div
                  key={idx}
                  className="text-xs bg-gray-50 p-1 rounded"
                >
                  <div className="flex justify-between">
                    <span className="truncate max-w-[60%]" title={item.store_name}>
                      {item.store_name}
                    </span>
                    <span className="font-mono">
                      {formatCurrency(item.total_revenue)}
                    </span>
                  </div>
                  <div className="text-xs text-gray-500 mt-0.5">
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
          <div>
            <div className="text-xs font-semibold text-gray-700 mb-1">
              Top Models
            </div>
            <div className="space-y-1 max-h-24 overflow-auto">
              {data.top_models.slice(0, 3).map((item, idx) => (
                <div
                  key={idx}
                  className="flex justify-between text-xs bg-gray-50 p-1 rounded"
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

