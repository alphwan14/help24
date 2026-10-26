/**
 * Where a signed-in admin lands. `/dashboard` itself only redirects here, so
 * sending anyone to `/dashboard` costs a second request (and, for a page load,
 * a second pass through middleware's identity check) to arrive at this.
 */
export const DASHBOARD_HOME = "/dashboard/overview";
