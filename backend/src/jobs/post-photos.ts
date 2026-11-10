/**
 * Which files in the public `post-images` bucket belong to a post's photos.
 *
 * The app uploads each photo as `posts/<uuid>.<ext>` and, from 1.0.10 Patch 3,
 * a feed thumbnail beside it as `posts/<uuid>.thumb.jpg` (mobile-app
 * utils/feed_images.dart). A deleted post must take both with it: the app's
 * "Delete post?" promises the images are deleted (audit 2026-10-29, D20).
 */
export const POST_IMAGES_BUCKET = 'post-images';

const PHOTO = /^(posts\/[A-Za-z0-9._-]+?)\.(jpe?g|png|gif|webp)$/i;

/**
 * Storage paths for [urls] (stored public URLs) and each photo's thumbnail.
 * Only `posts/` objects of THIS project are returned: a URL from another
 * host, another bucket or another folder is ignored, never deleted.
 */
export function postPhotoPaths(urls: readonly string[], projectUrl: string): string[] {
  const prefix = `${projectUrl.replace(/\/+$/, '')}/storage/v1/object/public/${POST_IMAGES_BUCKET}/`;
  const paths = new Set<string>();
  for (const url of urls) {
    if (typeof url !== 'string' || !url.startsWith(prefix)) continue;
    const path = decodeURIComponent(url.slice(prefix.length).split(/[?#]/)[0]);
    const m = PHOTO.exec(path);
    if (!m || path.includes('..')) continue;
    paths.add(path);
    if (!path.endsWith('.thumb.jpg')) paths.add(`${m[1]}.thumb.jpg`);
  }
  return [...paths];
}
