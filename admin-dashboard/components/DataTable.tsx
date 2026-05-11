interface Column<T> {
  key: string;
  label: string;
  render?: (row: T, index: number) => React.ReactNode;
}

interface DataTableProps<T extends Record<string, unknown>> {
  columns: Column<T>[];
  rows: T[];
  emptyMessage?: string;
}

export default function DataTable<T extends Record<string, unknown>>({
  columns,
  rows,
  emptyMessage = "No records found.",
}: DataTableProps<T>) {
  return (
    <div className="card overflow-hidden">
      {/* Horizontal scroll on narrow viewports */}
      <div className="overflow-x-auto -mx-px">
        <table className="w-full text-sm min-w-[540px]">
          <thead>
            <tr className="border-b border-gray-100 bg-gray-50/80">
              {columns.map((col) => (
                <th
                  key={col.key}
                  className="px-3 sm:px-4 py-3 text-left text-[11px] font-semibold text-gray-400 uppercase tracking-wider whitespace-nowrap"
                >
                  {col.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {rows.length === 0 ? (
              <tr>
                <td
                  colSpan={columns.length}
                  className="px-4 py-12 text-center text-sm text-gray-400"
                >
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              rows.map((row, i) => (
                <tr key={i} className="hover:bg-gray-50/60 transition-colors">
                  {columns.map((col) => (
                    <td
                      key={col.key}
                      className="px-3 sm:px-4 py-3 text-gray-700 whitespace-nowrap"
                    >
                      {col.render ? col.render(row, i) : String(row[col.key] ?? "—")}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
