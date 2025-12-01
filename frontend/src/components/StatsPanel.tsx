import React from "react";
import type { QueryResponse } from "../App";

interface StatsProps {
  data: QueryResponse | null;
  error: string | null;
}

const StatsPanel: React.FC<StatsProps> = ({ data, error }) => {
  if (error) {
    return (
      <div className="h-full flex flex-col p-3">
        <h2 className="text-sm font-semibold mb-2">Analytics</h2>
        <div className="text-xs text-red-600">Error: {error}</div>
      </div>
    );
  }

  if (!data) {
    return (
      <div className="h-full flex flex-col p-3">
        <h2 className="text-sm font-semibold mb-2">Analytics</h2>
        <div className="text-xs text-gray-500">
          Ask a question to see stats and sample records.
        </div>
      </div>
    );
  }

  const { stats, sample_records } = data;

  const renderMap = (obj: Record<string, number> | undefined) => {
    if (!obj || Object.keys(obj).length === 0) {
      return <div className="text-xs text-gray-400">No data.</div>;
    }
    return (
      <div className="space-y-1">
        {Object.entries(obj).map(([k, v]) => (
          <div key={k} className="flex justify-between text-xs">
            <span className="truncate max-w-[60%]" title={k}>
              {k}
            </span>
            <span className="font-mono">{v}</span>
          </div>
        ))}
      </div>
    );
  };

  return (
    <div className="h-full flex flex-col p-3 space-y-3 text-sm">
      <div>
        <h2 className="text-sm font-semibold text-gray-800 mb-1">
          Analytics
        </h2>
        <p className="text-xs text-gray-500">
          Grounded on the retrieved sales and feedback records.
        </p>
      </div>

      <div className="space-y-2">
        <div>
          <div className="text-xs font-semibold text-gray-700">
            Total Matches
          </div>
          <div className="text-lg font-semibold text-gray-900">
            {stats.total_matches}
          </div>
        </div>

        <div>
          <div className="text-xs font-semibold text-gray-700 mb-1">
            By Brand
          </div>
          {renderMap(stats.by_brand)}
        </div>

        <div>
          <div className="text-xs font-semibold text-gray-700 mb-1">
            By Store
          </div>
          {renderMap(stats.by_store)}
        </div>

        <div>
          <div className="text-xs font-semibold text-gray-700 mb-1">
            By Rating
          </div>
          {renderMap(stats.by_rating)}
        </div>
      </div>

      <div className="pt-2 border-t border-gray-200">
        <div className="text-xs font-semibold text-gray-700 mb-1">
          Sample Records
        </div>
        {(!sample_records || sample_records.length === 0) && (
          <div className="text-xs text-gray-400">No sample rows.</div>
        )}
        {sample_records && sample_records.length > 0 && (
          <div className="overflow-auto max-h-64 border border-gray-200 rounded">
            <table className="min-w-full text-xs">
              <thead className="bg-gray-100">
                <tr>
                  <th className="px-2 py-1 text-left font-semibold">
                    Brand
                  </th>
                  <th className="px-2 py-1 text-left font-semibold">
                    Store
                  </th>
                  <th className="px-2 py-1 text-left font-semibold">
                    Rating
                  </th>
                  <th className="px-2 py-1 text-left font-semibold">
                    Feedback
                  </th>
                </tr>
              </thead>
              <tbody>
                {sample_records.map((r, idx) => (
                  <tr
                    key={idx}
                    className={idx % 2 === 0 ? "bg-white" : "bg-gray-50"}
                  >
                    <td className="px-2 py-1 whitespace-nowrap">
                      {r.brand}
                    </td>
                    <td className="px-2 py-1 whitespace-nowrap">
                      {r.store_name}
                    </td>
                    <td className="px-2 py-1 whitespace-nowrap">
                      {r.feedback_rating}
                    </td>
                    <td
                      className="px-2 py-1 max-w-[160px] truncate"
                      title={r.customer_feedback}
                    >
                      {r.customer_feedback}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
};

export default StatsPanel;
