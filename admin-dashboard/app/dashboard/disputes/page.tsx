export default function DisputesPage() {
  return (
    <div className="space-y-6">
      <div className="card p-12 flex flex-col items-center justify-center text-center">
        <div className="w-14 h-14 rounded-full bg-amber-100 flex items-center justify-center mb-4">
          <svg className="w-7 h-7 text-amber-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m0-10.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.75c0 5.592 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.57-.598-3.75h-.152c-3.196 0-6.1-1.249-8.25-3.286zm0 13.036h.008v.008H12v-.008z" />
          </svg>
        </div>
        <h2 className="text-lg font-semibold text-gray-800">Disputes module not yet active</h2>
        <p className="text-gray-500 text-sm mt-2 max-w-sm">
          Dispute resolution workflows are planned for a future release. Add a{" "}
          <code className="bg-gray-100 px-1 py-0.5 rounded text-xs">disputes</code> table to Supabase
          to enable this feature.
        </p>
      </div>
    </div>
  );
}
