import React from 'react';
import { FONT } from '../config/theme';

/**
 * One consistent Android status bar (OS chrome, not Help24 UI), drawn over the
 * band that process_captures.py cleared. Same glyphs as the Play Store set, so
 * the captures' six different clock times and battery levels never flicker by.
 */
export const StatusBar: React.FC<{ color?: string }> = ({ color = '#12161A' }) => (
  <div
    style={{
      position: 'absolute',
      left: 0,
      top: 0,
      width: 1080,
      height: 84,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '0 46px',
      color,
      fontFamily: FONT,
    }}
  >
    <span style={{ fontSize: 38, fontWeight: 500, letterSpacing: '0.01em' }}>10:30</span>
    <span style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
      <svg width="42" height="42" viewBox="0 0 24 24" fill="none">
        <path d="M12 18.6a1.45 1.45 0 100-2.9 1.45 1.45 0 000 2.9z" fill="currentColor" />
        <path
          d="M8.2 14.2a5.6 5.6 0 017.6 0M4.9 10.8a10.3 10.3 0 0114.2 0M1.9 7.5a14.8 14.8 0 0120.2 0"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
        />
      </svg>
      <svg width="40" height="40" viewBox="0 0 24 24" fill="currentColor">
        <rect x="2" y="15" width="3.2" height="5" rx="1" />
        <rect x="7" y="12" width="3.2" height="8" rx="1" />
        <rect x="12" y="8.5" width="3.2" height="11.5" rx="1" />
        <rect x="17" y="5" width="3.2" height="15" rx="1" />
      </svg>
      <svg width="46" height="46" viewBox="0 0 28 24" fill="none">
        <rect x="1.9" y="7.2" width="21" height="10.6" rx="3.1" stroke="currentColor" strokeWidth="1.7" />
        <rect x="4.2" y="9.5" width="14.2" height="6" rx="1.7" fill="currentColor" />
        <path d="M24.9 10.9v3.2" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
      </svg>
    </span>
  </div>
);
