import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { App, initializeApp, getApps, cert } from 'firebase-admin/app';
import { getMessaging, Messaging } from 'firebase-admin/messaging';

@Injectable()
export class FirebaseAdminService implements OnModuleInit {
  private readonly logger = new Logger(FirebaseAdminService.name);
  private _app: App | null = null;

  onModuleInit(): void {
    const projectId   = process.env.FIREBASE_PROJECT_ID;
    const clientEmail = process.env.FIREBASE_CLIENT_EMAIL;
    // Render stores env vars as single-line strings — \n is literal backslash-n.
    const privateKey  = process.env.FIREBASE_PRIVATE_KEY?.replace(/\\n/g, '\n');

    if (!projectId || !clientEmail || !privateKey) {
      this.logger.warn(
        '[FCM][INIT] Firebase Admin NOT configured — set FIREBASE_PROJECT_ID, ' +
        'FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY in Render env vars',
      );
      return;
    }

    try {
      // Reuse existing app on NestJS hot reload (dev) to avoid duplicate-app errors.
      if (getApps().length > 0) {
        this._app = getApps()[0];
        this.logger.log(`[FCM][INIT] Firebase Admin reusing existing app (project=${projectId})`);
        return;
      }

      this._app = initializeApp({
        credential: cert({ projectId, clientEmail, privateKey }),
      });

      this.logger.log(`[FCM][INIT] Firebase Admin initialized — project=${projectId}`);
    } catch (err) {
      this.logger.error(
        `[FCM][INIT] Initialization failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  get isReady(): boolean {
    return this._app !== null;
  }

  /** Returns the Messaging instance or null if Admin is not initialized. */
  getMessaging(): Messaging | null {
    if (!this._app) return null;
    return getMessaging(this._app);
  }
}
